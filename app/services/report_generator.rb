require 'json'

class ReportGenerator
  include ReportGenerators::Helpers

  FORMATS = {
    'json' => ReportGenerators::JsonReport,
    'markdown' => ReportGenerators::MarkdownReport,
    'html' => ReportGenerators::HtmlReport,
    'pdf' => ReportGenerators::PdfReport
  }.freeze

  def initialize(scan)
    @scan = scan
    @findings = scan.findings_dataset.non_duplicate.exclude(severity: 'info').by_severity
    @target = scan.target
  end

  def generate(format)
    report = Report.create(scan_id: @scan.id, format: format, status: 'generating')
    formatter = build_formatter(format)

    content = formatter.generate
    local_path = save_local(content, formatter.filename)
    upload_and_finalize(report, local_path, formatter)
  rescue Sequel::ValidationFailed
    raise
  rescue StandardError => e
    report&.update(status: 'failed')
    Penetrator.logger.error("[ReportGenerator] Failed to generate #{format} report: #{e.message}")
    report
  end

  def generate_all
    %w[json markdown html pdf].map { |fmt| generate(fmt) }
  end

  # Expose private generate_json for backward compatibility with specs
  def generate_json
    ReportGenerators::JsonReport.new(scan: @scan, findings: @findings).generate
  end

  private

  def build_formatter(format)
    klass = FORMATS[format]
    raise ArgumentError, "Unknown report format: #{format}" unless klass

    if klass == ReportGenerators::JsonReport
      klass.new(scan: @scan, findings: @findings)
    else
      klass.new(scan: @scan, findings: @findings, target: @target)
    end
  end

  def upload_and_finalize(report, local_path, formatter)
    remote_path = "reports/#{@scan.target_id}/#{@scan.id}/#{formatter.filename}"
    storage = StorageService.new
    storage.upload(local_path, remote_path, content_type: formatter.content_type)

    url = begin
      storage.signed_url(remote_path)
    rescue StandardError => e
      Penetrator.logger.warn("[ReportGenerator] Signed URL unavailable: #{e.message}")
      nil
    end

    report.update(
      status: 'completed',
      gcs_path: remote_path,
      signed_url: url,
      signed_url_expires_at: url ? 7.days.from_now : nil
    )
    report
  end

  def save_local(content, filename)
    dir = Penetrator.root.join('tmp', 'reports', @scan.id)
    FileUtils.mkdir_p(dir)
    path = dir.join(filename)

    if content.is_a?(String) && content.encoding == Encoding::ASCII_8BIT
      File.binwrite(path, content)
    else
      File.write(path, content)
    end

    path.to_s
  end
end
