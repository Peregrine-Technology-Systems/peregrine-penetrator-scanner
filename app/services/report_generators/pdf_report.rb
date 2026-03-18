module ReportGenerators
  class PdfReport
    def initialize(scan:, findings:, target:)
      @html_generator = HtmlReport.new(scan:, findings:, target:)
      @scan = scan
    end

    def generate
      html_content = @html_generator.generate

      if defined?(Grover)
        grover = Grover.new(html_content, format: 'A4', print_background: true,
                                          margin: { top: '1cm', bottom: '1cm', left: '1cm', right: '1cm' })
        grover.to_pdf
      else
        Rails.logger.warn('[ReportGenerator] Grover not available, saving HTML as fallback')
        html_content
      end
    end

    def filename
      "scan_#{@scan.id}_report.pdf"
    end

    def content_type
      'application/pdf'
    end
  end
end
