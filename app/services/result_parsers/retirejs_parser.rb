module ResultParsers
  # Normalizes retire.js `--outputformat json` output into Finding hashes.
  # retire.js emits a flat object: {data:[{file, results:[{component, version,
  # vulnerabilities:[{severity, identifiers:{summary, CVE?:[]}, cwe?:[]}]}]}]}.
  # One Finding is produced per vulnerability (not per file/component). See #51.
  class RetirejsParser
    def initialize(output_file, target_url)
      @output_file = output_file
      @target_url  = target_url
    end

    def parse
      data = JSON.parse(File.read(@output_file)).fetch('data', [])
      data.flat_map { |item| parse_item(item) }
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[RetirejsParser] Parse error: #{e.message}")
      []
    end

    private

    def parse_item(item)
      item.fetch('results', []).flat_map do |result|
        result.fetch('vulnerabilities', []).map { |vuln| build_finding(result, vuln) }
      end
    end

    def build_finding(result, vuln)
      ids = vuln.fetch('identifiers', {})
      {
        source_tool: 'retirejs',
        severity: vuln['severity'],
        title: ids['summary'].to_s,
        url: @target_url,
        parameter: nil,
        cwe_id: Array(vuln['cwe']).first,
        cve_id: Array(ids['CVE']).first,
        evidence: {
          component: result['component'],
          version: result['version'],
          identifiers_summary: ids['summary'].to_s
        }.compact
      }
    end
  end
end
