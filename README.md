# Web Application Penetration Testing Platform

<!-- Badges -->
[![Build status](https://badge.buildkite.com/sample.svg?theme=github)](https://buildkite.com/chaudhuri-and-co/web-app-penetration-test)
![Ruby](https://img.shields.io/badge/ruby-3.2.2-CC342D?logo=ruby&logoColor=white)
![Rails](https://img.shields.io/badge/rails-7.1-CC0000?logo=rubyonrails&logoColor=white)
![Coverage](https://img.shields.io/badge/coverage-95.85%25-brightgreen)
![RuboCop](https://img.shields.io/badge/rubocop-0%20offenses-brightgreen)
![License](https://img.shields.io/badge/license-BSL%201.1-blue)
![Platform](https://img.shields.io/badge/platform-GCP-4285F4?logo=googlecloud&logoColor=white)

Automated security scanning platform that orchestrates best-in-class open-source tools against target web applications, aggregates findings, and generates professional reports.

> **v0.1.0** — See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what's new.

### Project Scope (March 2026)

| Metric | Count |
|--------|-------|
| Application code | 3,700 lines |
| Test code | 5,141 lines |
| Test:Code ratio | 1.39:1 |
| Test examples | 413 |
| Line coverage | 95.85% |
| RuboCop offenses | 0 |

---

## Ethics

All tools in this repository are for **authorized testing only**. Explicit written permission is required before scanning any target. Scope constraints are enforced programmatically. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## Architecture

```
Cloud Scheduler → Cloud Function → Ephemeral Spot VM → ScanOrchestrator
Buildkite CI    → trigger-scan.sh ↗                      ├── Discovery (ffuf + Nikto)
Dev CLI         → ./cloud/dev scan ↗                     ├── Active Scan (OWASP ZAP)
                                                          └── Targeted (Nuclei + sqlmap)
                                                               ↓
                                              FindingNormalizer → CVE Enrichment
                                                               ↓
                                              AI Analysis (Claude) → BigQuery Log
                                                               ↓
                                              ReportGenerator (JSON/MD/HTML/PDF) → Notify
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

### Cloud Development
```bash
./cloud/dev start          # Create/start GCP dev VM
./cloud/dev build          # Sync code + Docker build on VM
./cloud/dev scan quick     # Run scan, stream output
./cloud/dev results        # Download reports locally
./cloud/dev stop           # Stop VM (preserves Docker cache)
```

### Production
```bash
./cloud/dev scan-prod      # On-demand production scan (ephemeral spot VM)
# Scheduled: Cloud Scheduler triggers weekly Monday 2am UTC
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
