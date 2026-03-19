# CLAUDE.md

## Project Overview

Automated web application penetration testing platform built with Ruby on Rails. Orchestrates multiple open-source security scanning tools (OWASP ZAP, Nuclei, sqlmap, ffuf, Nikto) against target URLs, aggregates and deduplicates findings, enriches with CVE intelligence, applies AI analysis via Claude API, and generates professional reports.

## Build & Run Commands

- Install deps: `bundle install`
- Create DB: `rails db:create db:migrate`
- Run tests: `bundle exec rspec`
- Run single test: `bundle exec rspec spec/models/target_spec.rb`
- Lint: `bundle exec rubocop`
- Auto-fix lint: `bundle exec rubocop -A`
- List scan profiles: `bundle exec rake scan:profiles`
- Validate profiles: `bundle exec rake scan:validate_profiles`
- Run scan: `SCAN_PROFILE=standard TARGET_URLS='["https://example.com"]' bundle exec rake scan:run`
- Docker build: `docker build -f docker/Dockerfile -t pentest-platform .`
- Docker compose (with DVWA): `docker-compose -f docker/docker-compose.yml up`

## Architecture

```
ScanOrchestrator (central coordinator)
├── Phase 1 Discovery: FfufScanner + NiktoScanner (parallel)
├── Phase 2 Active: ZapScanner (full DAST scan)
└── Phase 3 Targeted: NucleiScanner + SqlmapScanner (parallel)
     ↓
FindingNormalizer (SHA256 fingerprint dedup)
     ↓
CveIntelligenceService (NVD, CISA KEV, EPSS, OSV enrichment)
     ↓
AiAnalyzer (Claude API triage + executive summary)
     ↓
ReportGenerator (JSON, Markdown, HTML, PDF via pandoc/xelatex) → StorageService (GCS/local)
     ↓
NotificationService (Slack webhook + email)
```

### Key Directories
- `app/models/` — Target, Scan, Finding, Report (UUID PKs), ScanProfile (value object)
- `app/services/` — Core services: ScanOrchestrator, FindingNormalizer, ReportGenerator, etc.
- `app/services/scanners/` — Tool-specific scanner classes extending ScannerBase
- `app/services/result_parsers/` — Normalize each tool's output format
- `app/views/reports/` — HTML report template (ERB)
- `config/scan_profiles/` — YAML scan configs (quick, standard, thorough)
- `docker/` — Dockerfile and docker-compose files
- `infra/` — Pulumi Ruby IaC for GCP
- `lib/tasks/scan.rake` — Rake tasks for running scans

### Data Models (all UUID primary keys)
- **Target** — name, urls (JSON), auth_type, scope_config, brand_config
- **Scan** — belongs_to Target, profile, status, tool_statuses (JSON), summary (JSON)
- **Finding** — belongs_to Scan, source_tool, severity, title, url, cwe_id, fingerprint, evidence (JSON)
- **Report** — belongs_to Scan, format (json/html/pdf), gcs_path, status

## Security & Ethics

- All tools in this repo are for **authorized testing only** — explicit written permission required before use against any target.
- Never hardcode credentials, API keys, or target information in source files.
- Scope constraints (target allowlists) must be enforced programmatically, not just documented.
- Environment variables for all secrets (see .env.example).
