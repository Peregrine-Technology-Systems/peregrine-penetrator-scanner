# Web Application Penetration Testing Platform

Automated security scanning platform that orchestrates best-in-class open-source tools against target web applications, aggregates findings, and generates professional reports.

## Architecture

```
Cloud Scheduler → Cloud Run Job → ScanOrchestrator
                                    ├── Phase 1: Discovery (ffuf + Nikto)
                                    ├── Phase 2: Active Scan (OWASP ZAP)
                                    └── Phase 3: Targeted (Nuclei + sqlmap)
                                         ↓
                                  FindingNormalizer → ReportGenerator → Notify
```

## Security Tool Stack

| Tool | Purpose |
|------|---------|
| OWASP ZAP | Primary DAST scanner |
| Nuclei | Template-based CVE scanning (11,000+ templates) |
| sqlmap | SQL injection detection |
| ffuf | Endpoint/directory discovery |
| Nikto | Server misconfiguration detection |
| Dawnscanner | Ruby dependency audit |

## Quick Start

### Prerequisites
- Docker & Docker Compose
- Ruby 3.2+ (for local development)

### Local Development
```bash
git clone https://github.com/Peregrine-Technology-Systems/web-app-penetration-test.git
cd web-app-penetration-test
bundle install
rails db:create db:migrate
bundle exec rspec
```

### Docker
```bash
docker build -f docker/Dockerfile -t pentest-platform .
docker run pentest-platform
```

### Run a Scan
```bash
# Quick scan
SCAN_PROFILE=quick TARGET_URLS='["https://example.com"]' rake scan:run

# Standard scan
SCAN_PROFILE=standard TARGET_URLS='["https://example.com"]' rake scan:run
```

## Scan Profiles

| Profile | Duration | Tools |
|---------|----------|-------|
| quick | ~10 min | ZAP baseline + Nuclei critical |
| standard | ~30 min | ZAP full + Nuclei + Nikto + ffuf |
| thorough | ~2 hours | All tools, deep crawl |

## Reports

Reports are generated in JSON, HTML, and PDF formats with professional branding. HTML reports are hosted via signed GCS URLs. PDF reports include executive summaries, severity charts, and detailed findings.

## AI Assessment

Claude API integration provides:
- False positive filtering
- Business impact assessment
- Attack chain correlation
- Executive report narratives
- Auto-generated Nuclei templates for new CVEs

## CVE Intelligence

Findings are enriched with data from:
- NVD API v2 (CVE details, CVSS scores)
- CISA KEV (known exploited vulnerabilities)
- EPSS (exploitation probability scores)
- OSV (open-source vulnerability data)

## Infrastructure

Deployed on GCP using Pulumi (Ruby):
- Cloud Run Job (4 vCPU, 16GB RAM)
- Cloud Scheduler (configurable cron)
- Cloud Storage (reports with 90-day lifecycle)
- Secret Manager (credentials)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT License](LICENSE)

## Ethics

All tools are for **authorized testing only**. Explicit written permission is required before scanning any target. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

