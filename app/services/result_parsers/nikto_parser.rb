module ResultParsers
  class NiktoParser
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

    def map_severity(vuln)
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

    def extract_cve(vuln)
      msg = vuln['msg'] || ''
      match = msg.match(/CVE-\d{4}-\d+/)
      match ? match[0] : nil
    end
  end
end
