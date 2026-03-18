require 'faraday'

module CveClients
  class NvdClient
    BASE_URL = 'https://services.nvd.nist.gov/rest/json/cves/2.0'.freeze

    def initialize(http)
      @http = http
    end

    def fetch(cve_id)
      response = @http.get(BASE_URL, { cveId: cve_id }) do |req|
        req.headers['apiKey'] = ENV['NVD_API_KEY'] if ENV['NVD_API_KEY'].present?
      end
      return nil unless response.success?

      response.body['vulnerabilities']&.first&.dig('cve')
    rescue StandardError => e
      Rails.logger.error("[CveIntelligence] NVD fetch failed for #{cve_id}: #{e.message}")
      nil
    end

    def extract_cvss(cve_data)
      metrics = cve_data['metrics'] || {}
      v31 = metrics['cvssMetricV31']&.first&.dig('cvssData', 'baseScore')
      v30 = metrics['cvssMetricV30']&.first&.dig('cvssData', 'baseScore')
      v2 = metrics['cvssMetricV2']&.first&.dig('cvssData', 'baseScore')
      v31 || v30 || v2
    end

    def extract_description(cve_data)
      descriptions = cve_data['descriptions'] || []
      en_desc = descriptions.find { |d| d['lang'] == 'en' }
      en_desc&.dig('value')
    end

    def extract_references(cve_data)
      refs = cve_data['references'] || []
      refs.map { |r| { url: r['url'], source: r['source'], tags: r['tags'] } }
    end

    def extract_affected_products(cve_data)
      configs = cve_data['configurations'] || []
      configs.flat_map do |config|
        (config['nodes'] || []).flat_map do |node|
          (node['cpeMatch'] || []).select { |m| m['vulnerable'] }.pluck('criteria')
        end
      end
    end
  end
end
