# frozen_string_literal: true

class AiAnalyzer
  MAX_FINDINGS_PER_REQUEST = 20
  MAX_FINDINGS_FOR_TRIAGE = 50

  def initialize
    @claude_client = Ai::ClaudeClient.new
    @triager = Ai::FindingTriager.new(@claude_client)
    @summarizer = Ai::ExecutiveSummarizer.new(@claude_client)
  end

  def analyze_scan(scan)
    findings = scan.findings.non_duplicate.order(severity_order)
    total_count = findings.count
    Rails.logger.info("[AiAnalyzer] Analyzing #{total_count} findings for #{scan.target.name}")

    triage_candidates = if total_count > MAX_FINDINGS_FOR_TRIAGE
                          Rails.logger.info("[AiAnalyzer] #{total_count} findings exceeds cap of #{MAX_FINDINGS_FOR_TRIAGE}, " \
                                            'triaging top findings by severity only')
                          findings.limit(MAX_FINDINGS_FOR_TRIAGE)
                        else
                          findings
                        end

    triage_candidates.each_slice(MAX_FINDINGS_PER_REQUEST) do |batch|
      triage_findings(batch, scan.target)
    end

    generate_executive_summary(scan)
  end

  def triage_findings(findings, target)
    @triager.triage_findings(findings, target)
  end

  def generate_executive_summary(scan)
    @summarizer.generate_executive_summary(scan)
  end

  def suggest_additional_tests(scan, discovery_results)
    prompt = <<~PROMPT
      You are a penetration tester reviewing Phase 1 discovery results to plan targeted testing.

      Target: #{scan.target.name}
      Discovered endpoints: #{discovery_results.take(50).to_json}

      Based on these discovered endpoints, suggest:
      1. Specific URLs that look promising for SQL injection testing
      2. Endpoints that might have authentication/authorization issues
      3. API endpoints that should be tested for IDOR or mass assignment
      4. Any interesting file paths that suggest misconfigurations

      Respond with JSON: { "sqli_targets": [...], "auth_targets": [...], "api_targets": [...], "misconfig_targets": [...] }
    PROMPT

    response = @claude_client.call_claude(prompt)
    @claude_client.parse_json_response(response)
  rescue StandardError => e
    Rails.logger.error("[AiAnalyzer] Adaptive scan suggestions failed: #{e.message}")
    {}
  end

  private

  def severity_order
    Arel.sql("CASE severity
      WHEN 'critical' THEN 1
      WHEN 'high' THEN 2
      WHEN 'medium' THEN 3
      WHEN 'low' THEN 4
      WHEN 'info' THEN 5
      ELSE 6 END")
  end
end
