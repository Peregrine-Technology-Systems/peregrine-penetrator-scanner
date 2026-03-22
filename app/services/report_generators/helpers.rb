module ReportGenerators
  module Helpers
    def finding_to_hash(finding)
      {
        id: finding.id,
        source_tool: finding.source_tool,
        severity: finding.severity,
        title: finding.title,
        url: finding.url,
        parameter: finding.parameter,
        cwe_id: finding.cwe_id,
        cve_id: finding.cve_id,
        cvss_score: finding.cvss_score,
        epss_score: finding.epss_score,
        kev_known_exploited: finding.kev_known_exploited,
        evidence: finding.evidence,
        ai_assessment: finding.ai_assessment
      }
    end

    def parse_brand_config(target)
      config = target.brand_config || {}
      {
        company_name: config['company_name'] || 'Peregrine Technology Systems',
        logo_url: config['logo_url'],
        primary_color: config['primary_color'] || '#1a365d',
        accent_color: config['accent_color'] || '#e53e3e',
        footer_text: config['footer_text'] || 'CONFIDENTIAL - Authorized Recipients Only'
      }
    end
  end
end
