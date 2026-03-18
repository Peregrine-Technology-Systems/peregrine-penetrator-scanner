# frozen_string_literal: true

module Ai
  class ExecutiveSummarizer
    def initialize(claude_client)
      @claude_client = claude_client
    end

    def generate_executive_summary(scan)
      summary = scan.summary || {}
      findings = scan.findings.non_duplicate

      critical_high = findings.where(severity: %w[critical high]).map do |f|
        finding_summary(f)
      end

      prompt = <<~PROMPT
        You are a cybersecurity consultant writing an executive summary for a penetration test report.

        Target: #{scan.target.name}
        Scan Profile: #{scan.profile}
        Duration: #{scan.duration&.to_i} seconds
        Total Findings: #{summary['total_findings']}
        By Severity: #{JSON.generate(summary['by_severity'] || {})}

        Critical and High findings:
        #{JSON.pretty_generate(critical_high)}

        Write a professional executive summary (3-4 paragraphs) that includes:
        1. Overall security posture assessment
        2. Key risk areas and their business impact
        3. Prioritized remediation roadmap
        4. Positive security observations (if any can be inferred)

        Write for a non-technical executive audience. Be direct and actionable.
      PROMPT

      response = @claude_client.call_claude(prompt)

      scan.update!(summary: summary.merge('executive_summary' => response))
      response
    rescue StandardError => e
      Rails.logger.error("[AiAnalyzer] Executive summary failed: #{e.message}")
      nil
    end

    private

    def finding_summary(finding)
      {
        id: finding.id,
        severity: finding.severity,
        title: finding.title,
        url: finding.url,
        cwe_id: finding.cwe_id,
        source_tool: finding.source_tool
      }.compact
    end
  end
end
