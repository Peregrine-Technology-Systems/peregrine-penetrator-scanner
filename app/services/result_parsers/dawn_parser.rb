module ResultParsers
  class DawnParser
    SEVERITY_MAP = {
      'critical' => 'critical',
      'high' => 'high',
      'medium' => 'medium',
      'low' => 'low',
      'info' => 'info'
    }.freeze

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      data = JSON.parse(File.read(@output_file))
      vulnerabilities = data['vulnerabilities'] || []

      vulnerabilities.map do |vuln|
        {
          source_tool: 'dawn',
          severity: SEVERITY_MAP[vuln['severity']&.downcase] || 'medium',
          title: vuln['name'] || vuln['title'],
          url: nil,
          parameter: nil,
          cwe_id: vuln['cwe'],
          cve_id: vuln['cve'],
          evidence: {
            description: vuln['description'],
            remediation: vuln['remediation'],
            affected_gem: vuln['gem_name'],
            affected_version: vuln['gem_version']
          }.compact
        }
      end
    rescue JSON::ParserError, Errno::ENOENT => e
      Rails.logger.error("[DawnParser] Parse error: #{e.message}")
      []
    end
  end
end
