module Trackers
  class GithubTracker
    API_BASE = 'https://api.github.com'.freeze

    def initialize(owner:, repo:, token:)
      @owner = owner
      @repo = repo
      @http = build_client(token)
    end

    def create_issue(finding, target_name)
      body = build_body(finding, target_name)
      labels = build_labels(finding)

      response = @http.post(issues_path) do |req|
        req.body = { title: issue_title(finding), body:, labels: }.to_json
      end

      parse_response(response)
    rescue StandardError => e
      Penetrator.logger.error("[GithubTracker] Failed to create issue: #{e.message}")
      nil
    end

    def self.configured?(target)
      config = target.ticket_config
      return false unless config.is_a?(Hash)

      %w[owner repo token_env].all? { |key| config[key].present? }
    end

    private

    def issue_title(finding)
      "[#{finding.severity.upcase}] #{finding.title}"
    end

    def build_body(finding, target_name)
      sections = [
        "## #{finding.title}",
        "**Target:** #{target_name}",
        "**Severity:** #{finding.severity.capitalize}",
        "**URL:** #{finding.url}",
        finding.cwe_id.present? ? "**CWE:** [#{finding.cwe_id}](https://cwe.mitre.org/data/definitions/#{finding.cwe_id.delete_prefix('CWE-')}.html)" : nil,
        finding.cve_id.present? ? "**CVE:** [#{finding.cve_id}](https://nvd.nist.gov/vuln/detail/#{finding.cve_id})" : nil,
        "**Scanner:** #{finding.source_tool}",
        remediation_section(finding),
        evidence_section(finding),
        "\n---\n*Created by Peregrine Penetration Test Platform*"
      ]

      sections.compact.join("\n\n")
    end

    def remediation_section(finding)
      remediation = finding.ai_assessment&.dig('remediation')
      return nil if remediation.blank?

      "### Remediation\n\n#{remediation}"
    end

    def evidence_section(finding)
      return nil if finding.evidence.blank?

      summary = finding.evidence.is_a?(Hash) ? finding.evidence.to_json : finding.evidence.to_s
      "### Evidence\n\n```\n#{summary.truncate(2000)}\n```"
    end

    def build_labels(finding)
      ['pentest', finding.severity]
    end

    def issues_path
      "/repos/#{@owner}/#{@repo}/issues"
    end

    def build_client(token)
      Faraday.new(url: API_BASE) do |f|
        f.request :json
        f.response :json
        f.headers['Authorization'] = "Bearer #{token}"
        f.headers['Accept'] = 'application/vnd.github+json'
        f.options.timeout = 15
        f.options.open_timeout = 10
      end
    end

    def parse_response(response)
      return nil unless response.success?

      data = response.body
      {
        ticket_ref: "#{@owner}/#{@repo}##{data['number']}",
        ticket_url: data['html_url']
      }
    end
  end
end
