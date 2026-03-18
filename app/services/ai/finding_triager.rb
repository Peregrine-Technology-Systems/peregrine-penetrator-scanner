# frozen_string_literal: true

module Ai
  class FindingTriager
    def initialize(claude_client)
      @claude_client = claude_client
    end

    def triage_findings(findings, target)
      findings_data = findings.map { |f| finding_summary(f) }

      prompt = <<~PROMPT
        You are a senior penetration tester reviewing automated scan findings.

        Target: #{target.name}
        URLs: #{target.url_list.join(', ')}

        Review these #{findings.count} findings and for each one provide:
        1. false_positive_likelihood: "high", "medium", or "low"
        2. business_impact: brief assessment of real-world impact
        3. priority: "immediate", "short_term", "long_term", or "accept_risk"
        4. remediation: specific, actionable fix recommendation
        5. attack_chain: how this finding could be combined with others

        Findings:
        #{JSON.pretty_generate(findings_data)}

        Respond with a JSON array matching the finding order. Each element should have the 5 fields above.
      PROMPT

      response = @claude_client.call_claude(prompt)
      assessments = @claude_client.parse_json_response(response)

      findings.each_with_index do |finding, idx|
        next unless assessments[idx]

        finding.update!(ai_assessment: assessments[idx])
      end
    rescue StandardError => e
      Rails.logger.error("[AiAnalyzer] Triage failed: #{e.message}")
    end

    private

    def finding_summary(finding)
      {
        id: finding.id,
        severity: finding.severity,
        title: finding.title,
        url: finding.url,
        parameter: finding.parameter,
        cwe_id: finding.cwe_id,
        cve_id: finding.cve_id,
        source_tool: finding.source_tool,
        cvss_score: finding.cvss_score,
        epss_score: finding.epss_score,
        kev_exploited: finding.kev_known_exploited
      }.compact
    end
  end
end
