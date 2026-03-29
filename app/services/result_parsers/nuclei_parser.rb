module ResultParsers
  class NucleiParser
    SEVERITY_MAP = {
      'critical' => 'critical',
      'high' => 'high',
      'medium' => 'medium',
      'low' => 'low',
      'info' => 'info',
      'unknown' => 'info'
    }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      return [] unless File.exist?(@output_file)

      File.readlines(@output_file).filter_map do |line|
        next if line.strip.empty?

        data = JSON.parse(line)
        {
          source_tool: 'nuclei',
          severity: SEVERITY_MAP[data.dig('info', 'severity')] || 'info',
          title: data.dig('info', 'name') || data['template-id'],
          url: data['matched-at'] || data['host'],
          parameter: data['matched-param'],
          cwe_id: extract_cwe(data),
          cve_id: extract_cve(data),
          cvss_score: extract_float(data, 'cvss-score'),
          cvss_vector: data.dig('info', 'classification', 'cvss-metrics'),
          epss_score: extract_float(data, 'epss-score'),
          evidence: {
            template_id: data['template-id'],
            template_url: data['template-url'],
            description: data.dig('info', 'description'),
            matcher_name: data['matcher-name'],
            extracted_results: data['extracted-results'],
            curl_command: data['curl-command']
          }.compact
        }
      rescue JSON::ParserError
        nil
      end
    end

    private

    def extract_cwe(data)
      cwe = data.dig('info', 'classification', 'cwe-id')
      return nil unless cwe

      cwe.is_a?(Array) ? cwe.first : cwe.to_s
    end

    def extract_float(data, key)
      val = data.dig('info', 'classification', key)
      val&.to_f
    end

    def extract_cve(data)
      cve = data.dig('info', 'classification', 'cve-id')
      return nil unless cve

      cve.is_a?(Array) ? cve.first : cve.to_s
    end
  end
end
