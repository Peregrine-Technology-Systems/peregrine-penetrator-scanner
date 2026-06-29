module ResultParsers
  class SqlmapParser
    def initialize(output_dir, url)
      @output_dir = output_dir
      @url = url
    end

    def parse
      log_file = find_log_file
      return [] unless log_file && File.exist?(log_file)

      content = File.read(log_file)

      content.scan(/Parameter: (.+?) \((.+?)\)/).map do |param, injection_type|
        build(param.strip, injection_type.strip, content)
      end
    end

    private

    def build(param, injection_type, content)
      Contract.finding(
        source_tool: 'sqlmap', probe: 'injection', finding_type: 'vulnerability',
        tool_check_id: injection_type, severity: 'high',
        title: "SQL Injection - #{injection_type}",
        location: Contract.web(url: @url, parameter: param),
        identifiers: [Contract.identifier('cwe', 'CWE-89')],
        evidence: { 'injection_type' => injection_type, 'log_excerpt' => extract_context(content, param) }
      )
    end

    def find_log_file
      return nil unless @output_dir.exist?

      Dir.glob(@output_dir.join('**', 'log')).first
    end

    def extract_context(content, param)
      lines = content.lines
      idx = lines.index { |l| l.include?(param) }
      return '' unless idx

      lines[[idx - 2, 0].max..[idx + 5, lines.length - 1].min].join
    end
  end
end
