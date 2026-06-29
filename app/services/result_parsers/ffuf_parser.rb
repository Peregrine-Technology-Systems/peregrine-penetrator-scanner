module ResultParsers
  class FfufParser
    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      (data['results'] || []).map { |result| build(result) }
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[FfufParser] Parse error: #{e.message}")
      []
    end

    private

    def build(result)
      Contract.finding(
        source_tool: 'ffuf', probe: 'content-discovery', finding_type: 'exposure',
        severity: severity_for_status(result['status']),
        title: "Discovered endpoint: #{result['input']&.values&.first || result['url']}",
        location: Contract.web(url: result['url']),
        evidence: {
          'status_code' => result['status'], 'content_length' => result['length'],
          'content_words' => result['words'], 'content_lines' => result['lines'],
          'content_type' => result['content-type'], 'redirect_location' => result['redirectlocation']
        }
      )
    end

    def severity_for_status(status)
      case status
      when 403 then 'low'
      else 'info'
      end
    end
  end
end
