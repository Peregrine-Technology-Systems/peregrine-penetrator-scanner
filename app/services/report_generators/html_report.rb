require 'erb'

module ReportGenerators
  class HtmlReport
    include Helpers

    def initialize(scan:, findings:, target:)
      @scan = scan
      @findings = findings
      @target = target
      @brand = parse_brand_config(target)
    end

    def generate
      template_path = Rails.root.join('app/views/reports/scan_report.html.erb')
      template = ERB.new(File.read(template_path))

      scan = @scan
      target = @target
      findings = @findings
      brand = @brand
      summary = @scan.summary || {}
      severity_counts = summary['by_severity'] || {}
      generated_at = Time.current

      template.result(binding)
    end

    def filename
      "scan_#{@scan.id}_report.html"
    end

    def content_type
      'text/html'
    end
  end
end
