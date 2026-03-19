require 'json'

module ReportGenerators
  class MarkdownReport
    include Helpers

    def initialize(scan:, findings:, target:)
      @scan = scan
      @findings = findings
      @target = target
      @brand = parse_brand_config(target)
    end

    def generate
      sections = []
      sections << executive_summary_section
      sections << findings_summary_section
      sections << '\newpage'
      sections << detailed_findings_section
      sections << '\newpage'
      sections << methodology_section
      sections << '\newpage'
      sections << appendix_section
      sections.compact.join("\n\n")
    end

    def filename
      "scan_#{@scan.id}_report.md"
    end

    def content_type
      'text/markdown'
    end

    private

    def cover_section
      date = format_date(@scan.completed_at || Time.current)
      profile = @scan.profile&.titleize || 'Standard'
      report_id = @scan.id.to_s.first(8).upcase

      <<~MARKDOWN
        # PENETRATION TEST REPORT

        **Target:** #{@target.name}
        **Assessment Date:** #{date}
        **Profile:** #{profile} Scan
        **Report ID:** #{report_id}
        **Classification:** CONFIDENTIAL

        Prepared by **#{@brand[:company_name]}**
      MARKDOWN
    end

    def executive_summary_section
      summary = @scan.summary || {}
      severity_counts = summary['by_severity'] || {}
      total = @findings.size
      critical = severity_counts['critical'].to_i
      high = severity_counts['high'].to_i
      medium = severity_counts['medium'].to_i
      low = severity_counts['low'].to_i
      info = severity_counts['info'].to_i

      risk_score = [
        (critical * 25) + (high * 15) + (medium * 8) + (low * 3) + (info * 0.5),
        100
      ].min.round

      risk_label = case risk_score
                   when 0..15 then 'Low'
                   when 16..40 then 'Moderate'
                   when 41..65 then 'High'
                   else 'Critical'
                   end

      tools_used = @findings.map(&:source_tool).compact.uniq
      duration = format_duration(@scan.duration)

      lines = []
      lines << '## Executive Summary'
      lines << ''
      lines << "**Overall Risk Level: #{risk_label}** (Score: #{risk_score}/100)"
      lines << ''
      lines << '### Key Metrics'
      lines << ''
      lines << '| Metric | Count |'
      lines << '|--------|------:|'
      lines << "| Total Findings | #{total} |"
      lines << "| Critical | #{critical} |"
      lines << "| High | #{high} |"
      lines << "| Medium | #{medium} |"
      lines << "| Low | #{low} |"
      lines << "| Informational | #{info} |"
      lines << ''
      lines << "**Scan Duration:** #{duration}"
      lines << "**Tools Executed:** #{tools_used.join(', ')}" if tools_used.any?

      if summary['executive_summary'].present?
        lines << ''
        lines << summary['executive_summary'].to_s
      end

      lines.join("\n")
    end

    def findings_summary_section
      return nil if @findings.empty?

      lines = []
      lines << '## Findings Summary'
      lines << ''
      lines << "#{@findings.size} finding(s) identified during this assessment:"
      lines << ''

      @findings.each_with_index do |f, idx|
        cwe = f.cwe_id.present? ? " | [#{f.cwe_id}](https://cwe.mitre.org/data/definitions/#{f.cwe_id.to_s.delete_prefix('CWE-')}.html)" : ''
        lines << "#{idx + 1}. **#{f.severity.upcase}** — #{f.title}"
        lines << "   - URL: #{f.url}" if f.url.present?
        lines << "   - Tool: #{f.source_tool}#{cwe}"
        lines << ''
      end

      lines.join("\n")
    end

    def detailed_findings_section
      return nil if @findings.empty?

      lines = []
      lines << '## Detailed Findings'

      @findings.each_with_index do |f, idx|
        lines << ''
        lines << "### #{idx + 1}. [#{f.severity.upcase}] #{f.title}"
        lines << ''
        lines << '| Field | Value |'
        lines << '|-------|-------|'
        lines << "| Severity | #{f.severity.upcase} |"
        lines << "| URL | `#{f.url}` |" if f.url.present?
        lines << "| Tool | #{f.source_tool} |"
        lines << "| Parameter | `#{f.parameter}` |" if f.parameter.present?
        lines << "| CWE | [#{f.cwe_id}](https://cwe.mitre.org/data/definitions/#{f.cwe_id.to_s.delete_prefix('CWE-')}.html) |" if f.cwe_id.present?
        lines << "| CVE | [#{f.cve_id}](https://nvd.nist.gov/vuln/detail/#{f.cve_id}) |" if f.cve_id.present?
        lines << "| CVSS | #{f.cvss_score} |" if f.cvss_score.present?
        lines << "| EPSS | #{format_epss(f.epss_score)} |" if f.epss_score.present?
        if f.kev_known_exploited
          lines << '| KEV | **ACTIVELY EXPLOITED** |'
        end

        if f.evidence.present?
          lines << ''
          lines << '#### Description / Evidence'
          lines << ''
          if f.evidence.is_a?(Hash)
            desc = f.evidence['description'] || f.evidence['desc']
            if desc.present?
              lines << desc.to_s
            else
              f.evidence.each do |key, val|
                lines << "**#{key.to_s.titleize}:** #{val}" if val.present?
              end
            end
          else
            lines << f.evidence.to_s
          end
        end

        if f.ai_assessment.present?
          lines << ''
          lines << '#### AI Assessment'
          lines << ''
          if f.ai_assessment.is_a?(Hash)
            if f.ai_assessment['summary'].present?
              lines << f.ai_assessment['summary'].to_s
            end
            if f.ai_assessment['recommendation'].present?
              lines << ''
              lines << '#### Remediation'
              lines << ''
              lines << f.ai_assessment['recommendation'].to_s
            end
          else
            lines << f.ai_assessment.to_s
          end
        end
      end

      lines.join("\n")
    end

    def methodology_section
      lines = []
      lines << '## Test Methodology'
      lines << ''
      lines << methodology_intro
      lines << ''
      lines << phase_overview
      lines << ''
      lines << tool_descriptions_table
      lines << ''
      lines << enrichment_section
      lines << ''
      lines << owasp_mapping_section

      lines.join("\n")
    end

    def appendix_section
      lines = []
      lines << '## Appendix'
      lines << ''
      lines << '### Tool Versions'
      lines << ''
      lines << '| Tool | Version |'
      lines << '|------|---------|'
      lines << '| OWASP ZAP | 2.17.0 (latest stable) |'
      lines << '| Nuclei | 3.7.1 (latest stable) |'
      lines << '| sqlmap | 1.10.3 (latest stable) |'
      lines << '| ffuf | 2.1.0 (latest stable) |'
      lines << '| Nikto | 2.6.0 (latest stable) |'
      lines << ''
      lines << '### Scan Configuration'
      lines << ''
      lines << "- **Profile:** #{@scan.profile&.titleize || 'Standard'}"
      lines << "- **Target URLs:** #{@target.url_list.join(', ')}"
      lines << "- **Started:** #{@scan.started_at&.strftime('%Y-%m-%d %H:%M %Z') || 'N/A'}"
      lines << "- **Completed:** #{@scan.completed_at&.strftime('%Y-%m-%d %H:%M %Z') || 'N/A'}"
      lines << "- **Duration:** #{format_duration(@scan.duration)}"

      tool_statuses = @scan.tool_statuses || {}
      if tool_statuses.any?
        lines << ''
        lines << '### Tool Execution Status'
        lines << ''
        lines << '| Tool | Status |'
        lines << '|------|--------|'
        tool_statuses.each do |name, status|
          lines << "| #{name} | #{status} |"
        end
      end

      lines << ''
      lines << '### Disclaimer'
      lines << ''
      lines << 'This penetration test was performed with explicit written authorization. '
      lines << 'The assessment was limited to the agreed-upon scope and test window. '
      lines << 'Findings represent vulnerabilities identified by automated scanning tools '
      lines << 'at the time of testing and may not represent a comprehensive view of all '
      lines << 'security issues. New vulnerabilities may emerge as software is updated or '
      lines << 'as new attack techniques are discovered.'
      lines << ''
      lines << "**#{@brand[:footer_text]}**"
      lines << ''
      lines << "*Report generated #{Time.current.strftime('%B %d, %Y at %H:%M %Z')}*"
      lines << "*Report ID: #{@scan.id}*"

      lines.join("\n")
    end

    # --- Helper methods ---

    def format_date(time)
      time&.strftime('%B %d, %Y') || 'N/A'
    end

    def format_duration(seconds)
      return 'N/A' unless seconds

      s = seconds.to_i
      if s > 3600
        "#{s / 3600}h #{(s % 3600) / 60}m"
      elsif s > 60
        "#{s / 60}m #{s % 60}s"
      else
        "#{s}s"
      end
    end

    def format_epss(score)
      return '' unless score

      "#{(score * 100).round(1)}%"
    end

    def truncate_url(url, max_length)
      return '' if url.blank?

      url.length > max_length ? "#{url[0..max_length]}..." : url
    end

    def escape_pipes(text)
      return '' if text.blank?

      text.gsub('|', '\\|')
    end

    def methodology_intro
      'This assessment employed a multi-layered scanning methodology combining five ' \
        'specialized security testing tools orchestrated in three phases: discovery, ' \
        'active scanning, and targeted exploitation testing. Results are aggregated, ' \
        'deduplicated using SHA-256 fingerprinting, enriched with CVE intelligence ' \
        '(NVD, CISA KEV, EPSS), and analyzed using AI-assisted triage to prioritize ' \
        'remediation efforts.'
    end

    def phase_overview
      <<~MARKDOWN
        ### Scanning Phases

        | Phase | Name | Tools | Description |
        |-------|------|-------|-------------|
        | 1 | Discovery | ffuf + Nikto | Content discovery and server audit run in parallel to map the attack surface |
        | 2 | Active Scanning | OWASP ZAP | Full DAST scan with active crawling and attack injection |
        | 3 | Targeted Testing | Nuclei + sqlmap | Template-based CVE scanning and SQL injection testing in parallel |
      MARKDOWN
    end

    def tool_descriptions_table
      <<~MARKDOWN
        ### Tool Descriptions

        | Tool | Category | Description |
        |------|----------|-------------|
        | OWASP ZAP | DAST Scanner | Full dynamic application security testing -- crawls and tests for XSS, CSRF, SQL injection, misconfigurations |
        | Nuclei | CVE & Template Scanner | 11,000+ vulnerability signatures, known CVEs, misconfigurations, default credentials |
        | sqlmap | SQL Injection Specialist | Systematic SQL injection testing across blind, error-based, UNION, stacked, and time-based techniques |
        | ffuf | Content Discovery | High-speed fuzzer for hidden paths, backup files, admin panels, undocumented API endpoints |
        | Nikto | Server Audit | 6,700+ checks for outdated software, dangerous HTTP methods, insecure headers |
      MARKDOWN
    end

    def enrichment_section
      <<~MARKDOWN
        ### Intelligence Enrichment

        - **AI-Assisted Analysis (Claude):** Contextual triage, false-positive assessment, remediation prioritization, and executive summary generation
        - **CVE Intelligence:** NVD for CVSS scores, CISA KEV for active exploitation status, EPSS for exploitation probability, OSV for open-source risks
      MARKDOWN
    end

    def owasp_mapping_section
      <<~MARKDOWN
        ### OWASP Top 10 Coverage

        | ID | Category | Tools | Tests |
        |----|----------|-------|-------|
        | A01 | Broken Access Control | ZAP | Path traversal, forced browsing, IDOR, CORS misconfiguration |
        | A02 | Cryptographic Failures | ZAP, Nikto | Insecure transport, weak TLS, missing HSTS |
        | A03 | Injection | ZAP, sqlmap | XSS (reflected, stored, DOM), SQL injection (all types), command injection |
        | A05 | Security Misconfiguration | ZAP, Nikto, Nuclei | Missing security headers, directory listing, verbose errors, default configs |
        | A06 | Vulnerable Components | Nuclei | Known CVE detection across 11,000+ templates |
        | A07 | Auth Failures | ZAP | Session management, insecure cookies, login over HTTP |
        | A09 | Logging & Monitoring | ZAP, Nikto | Information leakage, stack traces, version disclosure |
      MARKDOWN
    end
  end
end
