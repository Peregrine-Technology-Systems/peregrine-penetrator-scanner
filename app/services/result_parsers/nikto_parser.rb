module ResultParsers
  class NiktoParser
    SEVERITY_MAP_PATH = Penetrator.root.join('config/nikto_severity_map.yml')
    EMPTY_MAP = { 'by_id' => {}, 'by_osvdb' => {} }.freeze

    # Loaded once per process; stable Nikto id → severity. Memoized so a missing
    # or malformed file degrades to the keyword fallback rather than raising.
    def self.severity_map
      @severity_map ||= load_severity_map
    end

    def self.load_severity_map
      return EMPTY_MAP unless File.exist?(SEVERITY_MAP_PATH)

      loaded = YAML.safe_load_file(SEVERITY_MAP_PATH) || {}
      EMPTY_MAP.merge(loaded.slice('by_id', 'by_osvdb'))
    rescue Psych::SyntaxError => e
      Penetrator.logger.error("[NiktoParser] Severity map parse error, using keyword fallback: #{e.message}")
      EMPTY_MAP
    end

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      vulnerabilities = data['vulnerabilities'] ||
                        data['host']&.flat_map { |h| h['vulnerabilities'] || [] } || []

      vulnerabilities.map do |vuln|
        {
          source_tool: 'nikto',
          severity: map_severity(vuln),
          title: vuln['msg'] || vuln['description'],
          url: vuln['url'],
          parameter: nil,
          cwe_id: nil,
          cve_id: extract_cve(vuln),
          evidence: {
            id: vuln['id'],
            osvdb: vuln['OSVDB'],
            method: vuln['method'],
            description: vuln['msg']
          }.compact
        }
      end
    rescue JSON::ParserError, Errno::ENOENT => e
      Penetrator.logger.error("[NiktoParser] Parse error: #{e.message}")
      []
    end

    private

    # Severity is driven from a stable Nikto identifier (test id, then OSVDB id)
    # via the maintained lookup; the keyword heuristic is only a fallback for
    # unmapped findings. A finding that matches neither the lookup nor any keyword
    # rule falls through to `info` — and that fall-through is logged (never silent)
    # so a reworded-message mis-map is observable instead of hiding a real
    # critical at the bottom of the report (#823).
    def map_severity(vuln)
      mapped = severity_from_lookup(vuln)
      return mapped if mapped

      inferred = infer_severity_from_message(vuln)
      log_unmapped(vuln) if inferred == 'info'
      inferred
    end

    def severity_from_lookup(vuln)
      map = self.class.severity_map
      id = vuln['id']&.to_s
      osvdb = vuln['OSVDB']&.to_s

      by_id = map['by_id'][id] if id && !id.empty?
      return by_id if by_id

      return unless osvdb && osvdb != '0'

      map['by_osvdb'][osvdb]
    end

    def infer_severity_from_message(vuln)
      msg = (vuln['msg'] || '').downcase
      if msg.include?('remote code') || msg.include?('rce') || msg.include?('command injection')
        'critical'
      elsif msg.include?('sql injection') || msg.include?('xss') || msg.include?('file inclusion')
        'high'
      elsif msg.include?('directory listing') || msg.include?('information disclosure')
        'medium'
      elsif msg.include?('outdated') || msg.include?('header')
        'low'
      else
        'info'
      end
    end

    def log_unmapped(vuln)
      Penetrator.logger.warn(
        '[NiktoParser] Unmapped finding fell through to info — pin it in ' \
        "config/nikto_severity_map.yml if it matters: id=#{vuln['id']} " \
        "osvdb=#{vuln['OSVDB']} msg=#{vuln['msg']}"
      )
    end

    def extract_cve(vuln)
      msg = vuln['msg'] || ''
      match = msg.match(/CVE-\d{4}-\d+/)
      match ? match[0] : nil
    end
  end
end
