require 'faraday'
require 'json'

class CveIntelligenceService
  def initialize
    @http = Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 30
      f.options.open_timeout = 10
    end
    @nvd = CveClients::NvdClient.new(@http)
    @epss = CveClients::EpssClient.new(@http)
    @kev = CveClients::KevClient.new(@http)
    @osv = CveClients::OsvClient.new(@http)
  end

  def enrich_finding(finding)
    return if finding.cve_id.blank?

    enrichments = {}
    enrich_from_nvd(finding, enrichments)
    enrich_from_epss(finding, enrichments)
    enrichments[:kev_known_exploited] = @kev.exploited?(finding.cve_id)

    finding.update!(enrichments.compact)
    log_enrichment(finding.cve_id, enrichments)
  rescue StandardError => e
    Penetrator.logger.error("[CveIntelligence] Failed to enrich #{finding.cve_id}: #{e.message}")
  end

  def enrich_scan(scan)
    findings_with_cve = scan.findings.where.not(cve_id: [nil, ''])
    Penetrator.logger.info("[CveIntelligence] Enriching #{findings_with_cve.count} findings with CVE data")

    findings_with_cve.find_each do |finding|
      enrich_finding(finding)
      sleep(0.7)
    end
  end

  def query_osv(package_name, ecosystem: 'RubyGems', version: nil)
    @osv.query(package_name, ecosystem:, version:)
  end

  private

  def enrich_from_nvd(finding, enrichments)
    nvd_data = @nvd.fetch(finding.cve_id)
    return unless nvd_data

    enrichments[:cvss_score] = @nvd.extract_cvss(nvd_data)
    enrichments[:evidence] = (finding.evidence || {}).merge(
      'nvd_description' => @nvd.extract_description(nvd_data),
      'nvd_references' => @nvd.extract_references(nvd_data),
      'affected_products' => @nvd.extract_affected_products(nvd_data)
    )
  end

  def enrich_from_epss(finding, enrichments)
    epss_data = @epss.fetch(finding.cve_id)
    enrichments[:epss_score] = epss_data['epss'].to_f if epss_data
  end

  def log_enrichment(cve_id, enrichments)
    Penetrator.logger.info(
      "[CveIntelligence] Enriched #{cve_id}: " \
      "CVSS=#{enrichments[:cvss_score]}, EPSS=#{enrichments[:epss_score]}, KEV=#{enrichments[:kev_known_exploited]}"
    )
  end
end
