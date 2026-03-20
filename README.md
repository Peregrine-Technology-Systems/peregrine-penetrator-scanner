# Web Application Penetration Testing Platform

<!-- Badges -->
![CI](https://github.com/Peregrine-Technology-Systems/web-app-penetration-test/actions/workflows/ci.yml/badge.svg)
![Coverage](https://img.shields.io/badge/coverage-94.64%25-brightgreen)
![License](https://img.shields.io/badge/license-BSL%201.1-blue)

Automated security scanning platform that orchestrates best-in-class open-source tools against target web applications, aggregates findings, and generates professional reports.

> **v0.1.0** — See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what's new.

---

## Ethics

All tools in this repository are for **authorized testing only**. Explicit written permission is required before scanning any target. Scope constraints are enforced programmatically. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

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

See [DEVELOPMENT.md](DEVELOPMENT.md) for full setup instructions, environment variables, and testing details.

### Docker
```bash
docker build --platform linux/amd64 -f docker/Dockerfile -t pentest-platform .

# Run a scan
docker run --platform linux/amd64 \
  -e SCAN_PROFILE=quick \
  -e TARGET_NAME="My App" \
  -e TARGET_URLS='["https://example.com"]' \
  -e ANTHROPIC_API_KEY="sk-..." \
  -v "$(pwd)/storage/reports:/app/storage/reports" \
  pentest-platform rake scan:run
```

### GCP Deployment
```bash
# Manual trigger
gcloud run jobs execute pentest-scanner --region=us-central1

# Scheduled: Cloud Scheduler runs weekly (Monday 2am UTC)
```

### Reports
Reports are generated in JSON, Markdown, HTML, and PDF formats. PDF reports feature:
- Branded title page with Peregrine falcon logo
- Clickable table of contents with PDF bookmarks
- CONFIDENTIAL watermark on content pages
- Test methodology appendix with OWASP Top 10 mapping
- Professional LaTeX typesetting via pandoc/xelatex

## Scan Profiles

| Profile | Duration | Tools |
|---------|----------|-------|
| quick | ~10 min | ZAP baseline + Nuclei critical |
| standard | ~30 min | ZAP full + Nuclei + Nikto + ffuf |
| thorough | ~2 hours | All tools, deep crawl |

## Documentation

| Document | Description |
|----------|-------------|
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture, data model, and design decisions |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Local setup, testing, environment configuration |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | GCP deployment, infrastructure, and operations |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | Version history and changelog |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Community standards and ethics |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[Business Source License 1.1](LICENSE) — Free for non-commercial use. Converts to Apache 2.0 on March 19, 2030.
