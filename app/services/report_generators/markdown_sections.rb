module ReportGenerators
  module MarkdownSections
    include MethodologyContent

    def methodology_section
      lines = []
      lines << '# Test Methodology'
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
      lines << '# Appendix'
      lines << ''
      lines.concat(tool_versions_table)
      lines.concat(scan_config_section)
      lines.concat(tool_status_section)
      lines.concat(disclaimer_section)

      lines.join("\n")
    end

    private

    def tool_versions_table
      [
        '## Tool Versions',
        '',
        '| Tool | Version |',
        '|------|---------|',
        '| OWASP ZAP | 2.17.0 (latest stable) |',
        '| Nuclei | 3.7.1 (latest stable) |',
        '| sqlmap | 1.10.3 (latest stable) |',
        '| ffuf | 2.1.0 (latest stable) |',
        '| Nikto | 2.6.0 (latest stable) |',
        ''
      ]
    end

    def scan_config_section
      [
        '## Scan Configuration',
        '',
        "- **Profile:** #{@scan.profile&.titleize || 'Standard'}",
        "- **Target URLs:** #{@target.url_list.join(', ')}",
        "- **Started:** #{@scan.started_at&.strftime('%Y-%m-%d %H:%M %Z') || 'N/A'}",
        "- **Completed:** #{@scan.completed_at&.strftime('%Y-%m-%d %H:%M %Z') || 'N/A'}",
        "- **Duration:** #{format_duration(@scan.duration)}"
      ]
    end

    def tool_status_section
      tool_statuses = @scan.tool_statuses || {}
      return [] unless tool_statuses.any?

      lines = ['', '## Tool Execution Status', '', '| Tool | Status |', '|------|--------|']
      tool_statuses.each do |name, info|
        stat = info.is_a?(Hash) ? info['status'] || info[:status] : info.to_s
        lines << "| #{sanitize(name)} | #{sanitize(stat)} |"
      end
      lines
    end

    def disclaimer_section
      [
        '',
        '## Disclaimer',
        '',
        'This penetration test was performed with explicit written authorization. ',
        'The assessment was limited to the agreed-upon scope and test window. ',
        'Findings represent vulnerabilities identified by automated scanning tools ',
        'at the time of testing and may not represent a comprehensive view of all ',
        'security issues. New vulnerabilities may emerge as software is updated or ',
        'as new attack techniques are discovered.',
        '',
        "**#{@brand[:footer_text]}**",
        '',
        "*Report generated #{Time.current.strftime('%B %d, %Y at %H:%M %Z')}*",
        "*Report ID: #{@scan.id}*"
      ]
    end
  end
end
