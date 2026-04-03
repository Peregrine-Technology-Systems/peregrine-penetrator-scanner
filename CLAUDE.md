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
├── mark_running → SlackNotifier.send_started (":rocket: Scan Started")
├── preflight_check (HTTP HEAD each target URL, 10s timeout — fail fast on bad URLs)
├── ControlPlaneLoop (30s heartbeat → GCS control/{uuid}/heartbeat.json + callback POST)
├── [smoke profile] → SmokeChecker (tools, GCS, secrets validation)
├── [scan profiles] →
│   ├── Phase 1 Discovery: FfufScanner + NiktoScanner (parallel)
│   ├── Phase 2 Active: ZapScanner (full DAST scan)
│   └── Phase 3 Targeted: NucleiScanner + SqlmapScanner (parallel)
│   (critical tool failure in phase 1 or connection errors → abort entire scan)
│        ↓
│   FindingNormalizer (SHA256 fingerprint dedup)
│        ↓
│   CveIntelligenceService (NVD, CISA KEV, EPSS, OSV enrichment)
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
- `app/services/smoke_checker.rb` — CI verification checks (tools, GCS, secrets) for smoke profile
- `config/scan_profiles/` — YAML scan configs (quick, standard, thorough, deep, smoke, smoke-test)
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
| `ci.yaml` | Push (all branches except main) | RSpec + RuboCop + check-release-notes + test-cloud-functions (parallel) |
| `build-base.yaml` | Push to development (Dockerfile.base changes) | Build + push scanner-base image |
| `build.yaml` | Push to staging | Build baked scanner:staging image |
| `deploy.yaml` | Push to staging/main | Staging: trigger scan VM. Main: tag staging as production |
| `promote.yaml` | Push to dev/staging | Auto-promote to next branch |
| `smoke-test.yaml` | Push to staging | Validate scan outputs in GCS (smoke profile) |
| `version-bump.yaml` | Push to main | Bump VERSION, update RELEASE_NOTES, create git tag, tag Docker image |
| `sync-back.yaml` | Tag v* | Sync RELEASE_NOTES back to development/staging (dedup headings, clear stale Unreleased) |

### Hybrid Docker Model
- **Development**: Clone code + `bundle install` at VM boot (no Docker build)
- **Staging**: Build baked `scanner:staging` image (freeze point, immutable)
- **Production**: Re-tag `scanner:staging` as `scanner:production` (zero rebuild, identical bytes)
- `VERSION` is a runtime env var, not baked into the image. Read via `Penetrator::VERSION`.

## VM Safety System

Scan VMs have 5 layers of protection against hung/orphaned instances:

| Layer | Mechanism | Timeout | What it catches |
|-------|-----------|---------|-----------------|
| **Preflight** | HTTP HEAD target URLs | 10s | Bad URLs, DNS failures, unreachable hosts |
| **Critical failure** | First tool or connection errors abort scan | Immediate | Target goes down mid-scan |
| **GCS heartbeat** | `control/{uuid}/heartbeat.json` every 30s | 5m stale = stuck | Hung scans with live containers |
| **Ruby timeout** | `Timeout.timeout(SCAN_TIMEOUT)` | 3600s | Scan exceeds global limit |
| **Shell timeout** | `timeout --signal=TERM --kill-after=60` | 3600s | Ruby process hangs |
| **Scavenger** | SSH + heartbeat check | 10m soft / 240m hard | All orphans |

### Scavenger Decision Matrix
- VM age <= 10m: skip (too young)
- Container running + fresh heartbeat (<5m): skip (actively working)
- Container running + stale heartbeat (>5m): delete (stuck)
- Container running + no heartbeat: skip (legacy)
- No container: delete
- Age > 240m: delete unconditionally

### Cloud Functions

4 Cloud Functions in `cloud/scheduler/`:

| Function | Entry point | Purpose |
|----------|-------------|---------|
| `vm-scavenger` | `scavenge_vms` | Delete orphaned scan VMs (Cloud Scheduler, every 5m) |
| `trigger-scan-development` | `trigger_development` | Launch dev scan VM |
| `trigger-scan-staging` | `trigger_staging` | Launch staging scan VM |
| `trigger-scan-production` | `trigger_production` | Launch production scan VM (SPOT pricing) |

**Health guard:** `request.method == 'GET'` returns health (primary). `request.path == '/health'` as secondary. GET requests never trigger scans.

**Deploy:** `scripts/deploy-cloud-functions.sh` — deploys all 4 functions + verifies health endpoints return 200. Must be run manually after code changes.

**Python tests:** `cd cloud/scheduler && python3 -m pytest test_main.py -v` (uses Flask test_request_context, not MagicMock). Run in CI via `test-cloud-functions` step in Docker.

## Security & Ethics

- All tools in this repo are for **authorized testing only** — explicit written permission required before use against any target.
- **Authorized test target**: `https://auxscan.app.data-estate.cloud` — approved for development, staging, and production scans and smoke tests.
- Never hardcode credentials, API keys, or target information in source files.
- Scope constraints (target allowlists) must be enforced programmatically, not just documented.
- Environment variables for all secrets (see .env.example).
