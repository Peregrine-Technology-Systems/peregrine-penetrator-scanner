require 'erb'

module ReportGenerators
  class HtmlReport
    include Helpers
    include MarkdownConverter
    include ReportStyles

    def initialize(scan:, findings:, target:)
      @scan = scan
      @findings = findings
      @target = target
      @brand = parse_brand_config(target)
    end

    def generate
      md_generator = MarkdownReport.new(scan: @scan, findings: @findings, target: @target)
      md_content = md_generator.generate
      html_body = metrics_html + markdown_to_html(md_content)
      wrap_in_html(html_body)
    end

    def filename
      "scan_#{@scan.id}_report.html"
    end

    def content_type
      'text/html'
    end

    private

    def metrics_html
      summary = @scan.summary || {}
      sev = summary['by_severity'] || {}

      <<~HTML
        <h2>Key Metrics</h2>
        <table>
          <thead><tr><th>Metric</th><th>Count</th></tr></thead>
          <tbody>
            <tr><td>Total Findings</td><td>#{@findings.size}</td></tr>
            <tr><td>Critical</td><td>#{sev['critical'].to_i}</td></tr>
            <tr><td>High</td><td>#{sev['high'].to_i}</td></tr>
            <tr><td>Medium</td><td>#{sev['medium'].to_i}</td></tr>
            <tr><td>Low</td><td>#{sev['low'].to_i}</td></tr>
          </tbody>
        </table>
        <p><em>Informational findings are available at higher service tiers via the online portal.</em></p>
      HTML
    end

    def logo_data_uri
      logo_path = Penetrator.root.join('app/assets/images/peregrine_logo_embossed.jpg')
      return nil unless File.exist?(logo_path)

      "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(logo_path))}"
    end

    def wrap_in_html(body)
      css = report_css(@brand[:accent_color])
      logo_uri = logo_data_uri
      logo_html = logo_uri ? "<img src=\"#{logo_uri}\" alt=\"#{@brand[:company_name]}\" style=\"height:48px\">" : ''

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Penetration Test Report &mdash; #{@target.name} | #{@brand[:company_name]}</title>
          <style>
        #{css}  </style>
        </head>
        <body>
          <div class="report">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:2rem;padding-bottom:1rem;border-bottom:3px solid #{@brand[:accent_color]}">
              #{logo_html}
              <span style="color:#64748b;font-size:0.85rem">CONFIDENTIAL</span>
            </div>
            #{body}
            <div class="footer">
              <p>#{@brand[:footer_text]} &mdash; #{@brand[:company_name]}</p>
            </div>
          </div>
        </body>
        </html>
      HTML
    end
  end
end
