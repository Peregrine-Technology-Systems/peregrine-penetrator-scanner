require 'json'

module ReportGenerators
  class MarkdownReport
    include Helpers
    include MarkdownFormatters
    include MarkdownSections

    def initialize(scan:, findings:, target:)
      @scan = scan
      @findings = findings
      @target = target
      @brand = parse_brand_config(target)
    end

    def generate
      sections = []
      sections << metrics_section
      sections << executive_summary_text
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

    def metrics_section
      severity_counts = extract_severity_counts
      risk_score, risk_label = compute_risk_score_and_label(severity_counts)
      tools_used = @findings.map(&:source_tool).compact.uniq

      lines = ['## Metrics', '', "**Version:** #{report_version}", '']
      lines << "**Overall Risk Level: #{risk_label}** (Score: #{risk_score}/100)"
      lines << ''
      lines.concat(metrics_table(severity_counts))
      lines << ''
      lines << '*Note: Informational findings are available at higher service tiers via the online portal.*'
      lines << ''
      lines << "**Scan Duration:** #{format_duration(@scan.duration)}"
      lines << "**Tools Executed:** #{tools_used.join(', ')}" if tools_used.any?
      lines.join("\n")
    end

    def executive_summary_text
      text = (@scan.summary || {})['executive_summary']
      return nil if text.blank?

      "## Executive Summary\n\n#{text}"
    end

    def extract_severity_counts
      summary = @scan.summary || {}
      summary['by_severity'] || {}
    end

    def compute_risk_score_and_label(counts)
      critical = counts['critical'].to_i
      high = counts['high'].to_i
      medium = counts['medium'].to_i
      low = counts['low'].to_i
      info = counts['info'].to_i

      score = [
        (critical * 25) + (high * 15) + (medium * 8) + (low * 3) + (info * 0.5),
        100
      ].min.round

      label = case score
              when 0..15 then 'Low'
              when 16..40 then 'Moderate'
              when 41..65 then 'High'
              else 'Critical'
              end

      [score, label]
    end

    def metrics_table(counts)
      [
        '### Key Metrics',
        '',
        '| Metric | Count |',
        '|--------|------:|',
        "| Total Findings | #{@findings.size} |",
        "| Critical | #{counts['critical'].to_i} |",
        "| High | #{counts['high'].to_i} |",
        "| Medium | #{counts['medium'].to_i} |",
        "| Low | #{counts['low'].to_i} |"
      ]
    end

    def findings_summary_section
      return nil if @findings.empty?

      lines = []
      lines << '## Findings Summary'
      lines << ''
      lines << "#{@findings.size} finding(s) identified during this assessment:"
      lines << ''

      @findings.each_with_index do |f, idx|
        lines.concat(finding_summary_lines(f, idx))
      end

      lines.join("\n")
    end

    def finding_summary_lines(finding, idx)
      cwe_suffix = if finding.cwe_id.present?
                     cwe_num = finding.cwe_id.to_s.delete_prefix('CWE-')
                     " | [#{finding.cwe_id}](https://cwe.mitre.org/data/definitions/#{cwe_num}.html)"
                   else
                     ''
                   end
      lines = []
      lines << "#{idx + 1}. **#{finding.severity.upcase}** — #{finding.title}"
      lines << "   - URL: #{finding.url}" if finding.url.present?
      lines << "   - Tool: #{finding.source_tool}#{cwe_suffix}"
      lines << ''
      lines
    end

    MAX_DETAILED_FINDINGS = 50

    def detailed_findings_section
      return nil if @findings.empty?

      lines = []
      lines << '## Detailed Findings'

      if @findings.size > MAX_DETAILED_FINDINGS
        lines << ''
        lines << "Showing top #{MAX_DETAILED_FINDINGS} findings by severity. " \
                 "#{@findings.size - MAX_DETAILED_FINDINGS} additional findings available in JSON report."
      end

      display_findings = @findings.first(MAX_DETAILED_FINDINGS)

      display_findings.each_with_index do |f, idx|
        lines << ''
        lines << "### #{idx + 1}. [#{f.severity.upcase}] #{f.title}"
        lines << ''
        lines.concat(finding_metadata_table(f))
        lines.concat(finding_evidence(f))
        lines.concat(finding_ai_assessment(f))
      end

      lines.join("\n")
    end

    def finding_metadata_table(finding)
      lines = []
      lines << '| Field | Value |'
      lines << '|-------|-------|'
      lines << "| Severity | #{finding.severity.upcase} |"
      lines << "| URL | `#{finding.url}` |" if finding.url.present?
      lines << "| Tool | #{finding.source_tool} |"
      lines << "| Parameter | `#{finding.parameter}` |" if finding.parameter.present?
      append_cve_metadata(lines, finding)
      lines
    end

    def append_cve_metadata(lines, finding)
      if finding.cwe_id.present?
        cwe_num = finding.cwe_id.to_s.delete_prefix('CWE-')
        lines << "| CWE | [#{finding.cwe_id}](https://cwe.mitre.org/data/definitions/#{cwe_num}.html) |"
      end
      lines << "| CVE | [#{finding.cve_id}](https://nvd.nist.gov/vuln/detail/#{finding.cve_id}) |" if finding.cve_id.present?
      lines << "| CVSS | #{finding.cvss_score} |" if finding.cvss_score.present?
      lines << "| EPSS | #{format_epss(finding.epss_score)} |" if finding.epss_score.present?
      lines << '| KEV | **ACTIVELY EXPLOITED** |' if finding.kev_known_exploited
    end

    def finding_evidence(finding)
      return [] if finding.evidence.blank?

      lines = ['', '#### Description / Evidence', '']
      if finding.evidence.is_a?(Hash)
        lines.concat(finding_evidence_hash(finding.evidence))
      else
        lines << sanitize_text(finding.evidence.to_s)
      end
      lines
    end

    def finding_evidence_hash(evidence)
      desc = evidence['description'] || evidence['desc']
      return [sanitize_text(desc.to_s)] if desc.present?

      evidence.filter_map do |key, val|
        "**#{key.to_s.titleize}:** #{sanitize_text(val.to_s)}" if val.present?
      end
    end

    def finding_ai_assessment(finding)
      return [] if finding.ai_assessment.blank?

      lines = ['', '#### AI Assessment', '']
      if finding.ai_assessment.is_a?(Hash)
        lines << finding.ai_assessment['summary'].to_s if finding.ai_assessment['summary'].present?
        if finding.ai_assessment['recommendation'].present?
          lines << ''
          lines << '#### Remediation'
          lines << ''
          lines << finding.ai_assessment['recommendation'].to_s
        end
      else
        lines << finding.ai_assessment.to_s
      end
      lines
    end
  end
end
