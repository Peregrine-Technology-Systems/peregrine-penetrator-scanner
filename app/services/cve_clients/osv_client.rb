require 'faraday'

module CveClients
  class OsvClient
    BASE_URL = 'https://api.osv.dev/v1'.freeze

    def initialize(http)
      @http = http
    end

    def query(package_name, ecosystem: 'RubyGems', version: nil)
      payload = { package: { name: package_name, ecosystem: } }
      payload[:version] = version if version

      response = @http.post("#{BASE_URL}/query", payload)
      return [] unless response.success?

      (response.body['vulns'] || []).map do |vuln|
        {
          id: vuln['id'],
          summary: vuln['summary'],
          severity: extract_severity(vuln),
          aliases: vuln['aliases'],
          references: vuln['references']&.pluck('url')
        }
      end
    rescue StandardError => e
      Penetrator.logger.error("[CveIntelligence] OSV query failed: #{e.message}")
      []
    end

    private

    def extract_severity(vuln)
      severity = vuln.dig('database_specific', 'severity')
      return severity&.downcase if severity

      cvss = vuln['severity']&.first
      return nil unless cvss

      score = cvss['score']
      return nil unless score.is_a?(Numeric)

      case score
      when 9.0..10.0 then 'critical'
      when 7.0...9.0 then 'high'
      when 4.0...7.0 then 'medium'
      when 0.1...4.0 then 'low'
      else 'info'
      end
    end
  end
end
