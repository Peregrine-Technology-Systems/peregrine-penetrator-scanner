require 'faraday'

module CveClients
  class EpssClient
    BASE_URL = 'https://api.first.org/data/v1/epss'.freeze

    def initialize(http)
      @http = http
    end

    def fetch(cve_id)
      response = @http.get(BASE_URL, { cve: cve_id })
      return nil unless response.success?

      response.body['data']&.first
    rescue StandardError => e
      Penetrator.logger.error("[CveIntelligence] EPSS fetch failed for #{cve_id}: #{e.message}")
      nil
    end
  end
end
