module ResultParsers
  class FfufParser
    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      results = data['results'] || []

      results.map do |result|
        {
          source_tool: 'ffuf',
          severity: severity_for_status(result['status']),
          title: "Discovered endpoint: #{result['input']&.values&.first || result['url']}",
          url: result['url'],
          parameter: nil,
          cwe_id: nil,
          evidence: {
            status_code: result['status'],
            content_length: result['length'],
            content_words: result['words'],
            content_lines: result['lines'],
            content_type: result['content-type'],
            redirect_location: result['redirectlocation']
          }.compact
        }
      end
    rescue JSON::ParserError, Errno::ENOENT => e
      Rails.logger.error("[FfufParser] Parse error: #{e.message}")
      []
    end

    private

    def severity_for_status(status)
      case status
      when 200 then 'info'
      when 403 then 'low'
      when 301, 302 then 'info'
      else 'info'
      end
    end
  end
end
