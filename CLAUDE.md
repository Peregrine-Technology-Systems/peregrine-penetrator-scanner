# CLAUDE.md

## Project Overview

Security scanning engine built with Ruby + Sequel ORM. Orchestrates open-source penetration testing tools (OWASP ZAP, Nuclei, sqlmap, ffuf, Nikto) against target URLs, normalizes and deduplicates findings, enriches with CVE intelligence, and exports structured JSON results to GCS and BigQuery.

Report generation, AI analysis, ticketing, and email notifications have been extracted to the [reporter](https://github.com/Peregrine-Technology-Systems/peregrine-penetrator-reporter) and backend services.

## Build & Run Commands

- Install deps: `bundle install`
- Run tests: `bundle exec rspec`
- Run single test: `bundle exec rspec spec/models/target_spec.rb`
- Lint: `bundle exec rubocop`
- Auto-fix lint: `bundle exec rubocop -A`
- List scan profiles: `bundle exec rake scan:profiles`
- Validate profiles: `bundle exec rake scan:validate_profiles`
- Run scan: `bin/scan --profile standard --name "My App" --urls '["https://example.com"]'`
- Run scan (env vars): `SCAN_PROFILE=standard TARGET_NAME="My App" TARGET_URLS='["https://example.com"]' bin/scan`
- Docker build: `docker build -f docker/Dockerfile -t scanner .`

## Architecture

```
bin/scan (CLI entry point)
  ↓
ScanOrchestrator
├── Phase 1 Discovery: FfufScanner + NiktoScanner (parallel)
├── Phase 2 Active: ZapScanner (full DAST scan)
└── Phase 3 Targeted: NucleiScanner + SqlmapScanner (parallel)
     ↓
FindingNormalizer (SHA256 fingerprint dedup)
     ↓
CveIntelligenceService (NVD, CISA KEV, EPSS, OSV enrichment)
     ↓
ScanResultsExporter (v1.0 JSON envelope → GCS)
     ↓
BigQueryLogger (findings + metadata + costs)
     ↓
ScanCallbackService (POST to backend API)
     ↓
SlackNotifier (webhook)
```

### Key Directories
- `lib/penetrator.rb` — Boot module (replaces Rails): `.root`, `.logger`, `.env`, `.db`, `.boot!`
- `lib/models/` — Sequel models: Target, Scan, Finding (UUID PKs)
- `app/models/` — Value objects: ScanProfile
- `app/services/` — Core services: ScanOrchestrator, FindingNormalizer, ScanResultsExporter, etc.
- `app/services/scanners/` — Tool-specific scanner classes extending ScannerBase
- `app/services/result_parsers/` — Normalize each tool's output format
- `app/services/cve_clients/` — NVD, CISA KEV, EPSS, OSV API clients
- `config/scan_profiles/` — YAML scan configs (quick, standard, thorough)
- `bin/scan` — CLI entry point (supports ENV vars and flags)
- `db/sequel_migrations/` — Sequel migrations (targets, scans, findings)
- `docker/` — Dockerfile and docker-compose files
- `infra/` — Pulumi Ruby IaC for GCP

### Data Models (all UUID primary keys, Sequel ORM)
- **Target** — name, urls (JSON), auth_type, scope_config, brand_config
- **Scan** — many_to_one Target, one_to_many Findings, profile, status, tool_statuses (JSON), summary (JSON)
- **Finding** — many_to_one Scan, source_tool, severity, title, url, cwe_id, fingerprint, evidence (JSON)

### Sequel Notes
- JSON columns use `plugin :serialization, :json, :column_name`
- In-place hash mutations are NOT detected — always use `model.col = hash.merge(new_keys)` then `save_changes`
- Use `findings_dataset` (not `findings`) when chaining queries — `findings` returns a cached Array
- Dataset methods: `.count` (not `.size`), `.exclude` (not `.where.not`), `.find_or_create`

## CI/CD

CI runs on Woodpecker CI (self-hosted at d3ci42.peregrinetechsys.net). Pipeline configs in `.woodpecker/`. Secrets are Woodpecker repo-level secrets.

| Pipeline | Trigger | Steps |
|----------|---------|-------|
| `ci.yaml` | Push (all branches except main) | RSpec + RuboCop (parallel) |
| `build.yaml` | Push to development (Gemfile/Docker changes) | Docker build + push to Artifact Registry |
| `deploy.yaml` | Push to dev/staging/main | Tag image, trigger scan |
| `promote.yaml` | Push to dev/staging | Auto-promote to next branch |
| `smoke-test.yaml` | Push to staging | Validate scan outputs in GCS |

## Security & Ethics

- All tools in this repo are for **authorized testing only** — explicit written permission required before use against any target.
- Never hardcode credentials, API keys, or target information in source files.
- Scope constraints (target allowlists) must be enforced programmatically, not just documented.
- Environment variables for all secrets (see .env.example).
