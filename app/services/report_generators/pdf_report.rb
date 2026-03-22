require 'open3'

module ReportGenerators
  class PdfReport
    include Helpers
    include MarkdownFormatters

    def initialize(scan:, findings:, target:)
      @md_generator = MarkdownReport.new(scan:, findings:, target:)
      @scan = scan
      @target = target
    end

    def generate
      md_content = @md_generator.generate

      md_dir = Penetrator.root.join('tmp', 'reports', @scan.id)
      FileUtils.mkdir_p(md_dir)
      md_path = md_dir.join('report.md')
      File.write(md_path, md_content)

      # Copy transparent logo for LaTeX template (navy cover shows through)
      logo_src = Penetrator.root.join('app/assets/images/peregrine_logo_embossed_transparent.png')
      logo_dest = md_dir.join('peregrine_logo_embossed_transparent.png')
      FileUtils.cp(logo_src, logo_dest) if File.exist?(logo_src)

      pdf_path = md_dir.join('report.pdf')

      cmd = build_pandoc_command(md_path.to_s, pdf_path.to_s)

      _stdout, stderr, status = Open3.capture3(cmd, chdir: md_dir.to_s)

      if status.success? && File.exist?(pdf_path)
        File.binread(pdf_path)
      else
        Penetrator.logger.error("[PdfReport] pandoc failed (exit #{status.exitstatus}): #{stderr}")
        raise "PDF generation failed: #{stderr.lines.first&.strip}"
      end
    rescue StandardError => e
      Penetrator.logger.error("[PdfReport] PDF generation failed: #{e.message}")
      raise
    end

    def filename
      "scan_#{@scan.id}_report.pdf"
    end

    def content_type
      'application/pdf'
    end

    private

    def build_pandoc_command(md_path, pdf_path)
      template = Penetrator.root.join('config/report_templates/pentest_report.latex')
      date = @scan.completed_at&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y')

      summary = @scan.summary || {}
      sev = summary['by_severity'] || {}

      args = [
        'pandoc', md_path,
        '-o', pdf_path,
        '--pdf-engine=xelatex',
        "--template=#{template}",
        '-V', 'geometry:margin=1in',
        '-V', 'mainfont=DejaVu Sans',
        '-V', 'monofont=DejaVu Sans Mono',
        '-V', 'fontsize=11pt',
        '--highlight-style=tango',
        '-V', "title=#{@target.name}",
        '-V', "date=#{date}",
        '-V', "sev_critical=#{sev['critical'].to_i}",
        '-V', "sev_high=#{sev['high'].to_i}",
        '-V', "sev_medium=#{sev['medium'].to_i}",
        '-V', "sev_low=#{sev['low'].to_i}",
        '-V', "sev_info=#{sev['info'].to_i}",
        '-V', "sev_total=#{summary['total_findings'].to_i}",
        '-V', "version=#{report_version}"
      ]

      args.shelljoin
    end
  end
end
