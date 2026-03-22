require 'faraday'

module CveClients
  class KevClient
    CISA_KEV_URL = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json'.freeze

    def initialize(http)
      @http = http
      @cache = nil
      @cache_time = nil
    end

    def exploited?(cve_id)
      fetch_catalog.include?(cve_id)
    end

    private

    def fetch_catalog
      return @cache if @cache && @cache_time && (Time.current - @cache_time) < 1.hour

      response = @http.get(CISA_KEV_URL)
      return Set.new unless response.success?

      vulns = response.body['vulnerabilities'] || []
      @cache = Set.new(vulns.pluck('cveID'))
      @cache_time = Time.current
      @cache
    rescue StandardError => e
      Penetrator.logger.error("[CveIntelligence] KEV fetch failed: #{e.message}")
      @cache || Set.new
    end
  end
end
