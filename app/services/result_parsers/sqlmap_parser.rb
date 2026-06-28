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

      # Parse sqlmap log output for injection points
      content.scan(/Parameter: (.+?) \((.+?)\)/).map do |param, injection_type|
        {
          source_tool: 'sqlmap',
          severity: 'high',
          title: "SQL Injection - #{injection_type.strip}",
          url: @url,
          parameter: param.strip,
          cwe_id: 'CWE-89',
          evidence: {
            injection_type: injection_type.strip,
            url: @url,
            log_excerpt: extract_context(content, param)
          }
        }
      end
    end

    private

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
