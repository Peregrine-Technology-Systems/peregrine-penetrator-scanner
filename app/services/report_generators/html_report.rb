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

    def wrap_in_html(body)
      css = report_css(@brand[:accent_color])

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
