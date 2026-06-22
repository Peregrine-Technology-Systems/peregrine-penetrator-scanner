module ResultParsers
  # Normalizes testssl.sh `--jsonfile` output (a flat array of
  # {id, ip, port, severity, finding, cve?, cwe?}) into Finding hashes.
  # Severity mapping is config-driven (config/testssl_severity_map.yml); records
  # whose severity is unmapped (OK/DEBUG/FATAL) or whose ip is "/" (engine/cmdline
  # meta) are dropped — they are non-findings. See #48.
  class TestsslParser
    SEVERITY_MAP_PATH = Penetrator.root.join('config/testssl_severity_map.yml')

    # Strict on purpose: a missing/broken map must fail loud, never silently
    # yield zero findings (that would be the silent-OK class this guards against).
    def self.severity_map
      @severity_map ||= YAML.safe_load_file(SEVERITY_MAP_PATH).fetch('severity_map')
    end

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      JSON.parse(File.read(@output_file)).filter_map { |record| build_finding(record) }
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[TestsslParser] Parse error: #{e.message}")
      []
    end

    private

    def build_finding(record)
      severity = self.class.severity_map[record['severity']]
      return nil if severity.nil? || record['ip'] == '/'

      {
        source_tool: 'testssl',
        severity:,
        title: title_for(record),
        url: url_for(record['ip']),
        parameter: nil,
        cwe_id: record['cwe'],
        cve_id: first_cve(record['cve']),
        evidence: { id: record['id'], port: record['port'], testssl_severity: record['severity'] }.compact
      }
    end

    def title_for(record)
      finding = record['finding'].to_s.strip
      finding.empty? || finding == '--' ? record['id'] : finding
    end

    def url_for(ip)
      host = ip.to_s.split('/').first
      host.to_s.empty? ? nil : "https://#{host}"
    end

    def first_cve(cve)
      return nil if cve.to_s.strip.empty?

      cve.split(/\s+/).first
    end
  end
end
