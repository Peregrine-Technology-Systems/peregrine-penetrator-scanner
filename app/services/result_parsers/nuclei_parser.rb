module ResultParsers
  class NucleiParser
    SEVERITY_MAP = {
      'critical' => 'critical', 'high' => 'high', 'medium' => 'medium',
      'low' => 'low', 'info' => 'info', 'unknown' => 'info'
    }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      return [] unless File.exist?(@output_file)

      File.readlines(@output_file).filter_map do |line|
        next if line.strip.empty?

        build(JSON.parse(line))
      rescue JSON::ParserError
        nil
      end
    end

    private

    def build(data)
      sev = data.dig('info', 'severity')
      Contract.finding(
        source_tool: 'nuclei', probe: 'template-cve', finding_type: 'vulnerability',
        tool_check_id: data['template-id'],
        severity: SEVERITY_MAP[sev] || 'info', severity_source: sev,
        title: data.dig('info', 'name') || data['template-id'],
        description: data.dig('info', 'description'),
        location: Contract.web(url: data['matched-at'] || data['host'], parameter: data['matched-param']),
        identifiers: identifiers(data),
        scores: {
          'cvss_score' => extract_float(data, 'cvss-score'),
          'cvss_vector' => data.dig('info', 'classification', 'cvss-metrics'),
          'epss_score' => extract_float(data, 'epss-score')
        },
        evidence: {
          'template_url' => data['template-url'], 'matcher_name' => data['matcher-name'],
          'extracted_results' => data['extracted-results'], 'curl_command' => data['curl-command']
        }
      )
    end

    # Preserve EVERY CVE/CWE the template asserts (nuclei classification can be a
    # list) — the flat model kept only the first; identifiers[] is lossless (#971).
    def identifiers(data)
      classification(data, 'cve-id').map { |v| Contract.identifier('cve', v) } +
        classification(data, 'cwe-id').map { |v| Contract.identifier('cwe', v) }
    end

    def classification(data, key)
      Array(data.dig('info', 'classification', key)).map(&:to_s)
    end

    def extract_float(data, key)
      data.dig('info', 'classification', key)&.to_f
    end
  end
end
