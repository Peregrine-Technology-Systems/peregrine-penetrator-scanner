module ReportGenerators
  module MethodologyContent
    private

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
