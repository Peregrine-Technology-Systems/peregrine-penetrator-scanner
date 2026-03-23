# Peregrine Penetrator Scanner

<!-- Badges -->
[![Woodpecker CI](https://d3ci42.peregrinetechsys.net/api/badges/5/status.svg)](https://d3ci42.peregrinetechsys.net/repos/5)
![Ruby](https://img.shields.io/badge/ruby-3.2.2-CC342D?logo=ruby&logoColor=white)
![Sequel](https://img.shields.io/badge/ORM-Sequel-blue)
![Coverage](https://img.shields.io/badge/coverage-94.96%25-brightgreen)
![RuboCop](https://img.shields.io/badge/rubocop-0%20offenses-brightgreen)
![License](https://img.shields.io/badge/license-BSL%201.1-blue)
![Platform](https://img.shields.io/badge/platform-GCP-4285F4?logo=googlecloud&logoColor=white)

Automated security scanning engine that orchestrates open-source penetration testing tools against target web applications, normalizes and deduplicates findings, enriches with CVE intelligence, and exports structured results to GCS and BigQuery.

> **v0.3.0** — See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what's new.

### Design Approach

This project followed **stepwise refinement** — the classic Agile approach of building a working monolith first, then extracting clean service boundaries once the domain is understood. The scanner started as a single Rails application handling scanning, AI analysis, report generation, ticketing, and notifications (~3,700 lines, 38 gems, 300MB RAM). Through iterative development and refactoring, each responsibility was extracted to its own service as the boundaries became clear:

| Version | What happened |
|---------|--------------|
| v0.1.0 | Monolith — Rails app doing everything: scan, analyze, report, notify |
| v0.2.0 | Rails stripped — migrated to Sequel ORM + plain Ruby CLI (80MB RAM, <1s boot) |
| v0.3.0 | Service extraction — report generation, AI, ticketing, email moved to reporter and backend (-7,030 lines) |

The result is a focused engine (~1,150 lines, 15 gems) that does one thing well: scan targets and export structured results. You can't design clean service boundaries on day one — you have to build it, understand it, then refactor.

### Project Scope (March 2026)

| Metric | Value |
|--------|-------|
| Application code | ~1,150 lines |
| Test examples | 389 |
| Line coverage | 94.96% |
| RuboCop offenses | 0 |
| Gems | 15 |

---

## Ethics

All tools in this repository are for **authorized testing only**. Explicit written permission is required before scanning any target. Scope constraints are enforced programmatically. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## Architecture

The scanner is one component of a three-service platform:

| Service | Responsibility |
|---------|---------------|
| **Scanner** (this repo) | Orchestrate tools, normalize findings, export JSON to GCS |
| **Reporter** ([peregrine-penetrator-reporter](https://github.com/Peregrine-Technology-Systems/peregrine-penetrator-reporter)) | AI analysis, report generation (HTML/PDF), ticketing, email |
| **Backend** | Orchestration API, scheduling, billing, notifications |

```
Cloud Scheduler → Cloud Function → Ephemeral Spot VM → bin/scan
                                                          ├── Phase 1: Discovery (ffuf + Nikto)
                                                          ├── Phase 2: Active Scan (OWASP ZAP)
                                                          └── Phase 3: Targeted (Nuclei + sqlmap)
                                                               ↓
                                                FindingNormalizer (SHA256 dedup)
                                                               ↓
                                                CveIntelligenceService (NVD, CISA KEV, EPSS, OSV)
                                                               ↓
                                                ScanResultsExporter → GCS (v1.0 JSON envelope)
                                                               ↓
                                                BigQueryLogger (findings + metadata + costs)
                                                               ↓
                                                ScanCallbackService → Backend API
                                                               ↓
                                                SlackNotifier → Webhook
```

### VM Lifecycle
Scan VMs self-terminate on completion. A Cloud Function scavenger runs every 10 minutes as a safety net:
- VMs < 30 min old: left alone
- VMs 30 min – 4 hours: SSH liveness check — deletes only if no active scan
- VMs > 4 hours: force-deleted regardless of state

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
git clone https://github.com/Peregrine-Technology-Systems/peregrine-penetrator-scanner.git
cd peregrine-penetrator-scanner
bundle install
bundle exec rspec
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for full setup instructions and environment variables.

### Run a Scan
```bash
# Via CLI
bin/scan --profile quick --name "My App" --urls '["https://example.com"]'

# Via environment variables (Docker/VM)
SCAN_PROFILE=standard TARGET_NAME="My App" TARGET_URLS='["https://example.com"]' bin/scan

# Via Docker
docker build --platform linux/amd64 -f docker/Dockerfile -t scanner .
docker run --platform linux/amd64 \
  -e SCAN_PROFILE=quick \
  -e TARGET_NAME="My App" \
  -e TARGET_URLS='["https://example.com"]' \
  scanner
```

### Cloud Development
```bash
./cloud/dev start          # Create/start GCP dev VM
./cloud/dev build          # Sync code + Docker build on VM
./cloud/dev scan quick     # Run scan, stream output
./cloud/dev results        # Download results locally
./cloud/dev stop           # Stop VM (preserves Docker cache)
```

## Scan Profiles

| Profile | Duration | Tools |
|---------|----------|-------|
| quick | ~10 min | ZAP baseline + Nuclei critical |
| standard | ~30 min | ZAP full + Nuclei + Nikto + ffuf |
| thorough | ~2 hours | All tools, deep crawl |

## Key Design Decisions

- **Sequel ORM** over Rails/ActiveRecord — 80MB RAM, <1s boot, 15 gems (was 300MB, 5s, 38 gems)
- **Ephemeral VMs** — each scan runs on a fresh spot VM that self-terminates
- **JSON-first pipeline** — canonical v1.0 JSON envelope exported to GCS, then loaded to BigQuery
- **Separation of duties** — scanner scans, reporter reports, backend orchestrates

## Documentation

| Document | Description |
|----------|-------------|
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture, data model, and design decisions |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Local setup, testing, environment configuration |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | GCP deployment, infrastructure, and operations |
| [docs/schema_versioning.md](docs/schema_versioning.md) | v1.0 JSON envelope contract |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | Version history and changelog |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |

## Docker Image Architecture

The scanner uses a **hybrid model** — development is fast (no Docker build), staging/production use immutable baked images.

| Environment | How scan VMs run | Docker build? |
|-------------|-----------------|---------------|
| **Development** | Clone code from git + `bundle install` at boot | No |
| **Staging** | Pull `scanner:staging` baked image | Yes (on staging merge) |
| **Production** | Pull `scanner:production` (same image as staging, re-tagged) | No (tag only) |

### Images

| Image | Contents | Rebuilt when |
|-------|----------|-------------|
| `scanner-base` | Security tools (ZAP, Nuclei, sqlmap, ffuf, Nikto) + Ruby runtime | `Dockerfile.base` or `base-versions.txt` changes (monthly) |
| `scanner:staging` | `FROM scanner-base` + gems + app code (frozen) | Every staging merge |
| `scanner:production` | Same bytes as `scanner:staging` (re-tagged) | Main merge (tag only, no build) |

VERSION is an env var passed at runtime, not baked into the image. RELEASE_NOTES lives in git — updated on main after the image is built.

```
docker/
  Dockerfile.base      # Base: security tools + runtime (rebuilt rarely)
  Dockerfile           # Baked app image for staging/production
  base-versions.txt    # Pinned tool versions
```

## CI/CD

CI runs on [Woodpecker CI](https://d3ci42.peregrinetechsys.net) (self-hosted). Pipelines:

| Pipeline | Trigger | Steps |
|----------|---------|-------|
| `ci.yaml` | Push (all branches except main) | RSpec + RuboCop |
| `build-base.yaml` | Push to development (Dockerfile.base or base-versions.txt changes only) | Build + push scanner-base image |
| `build.yaml` | Push to staging | Build baked scanner:staging image |
| `deploy.yaml` | Push to staging/main | Staging: trigger scan VM. Main: tag staging as production |
| `promote.yaml` | Push to dev/staging | Auto-promote to next branch |
| `smoke-test.yaml` | Push to staging | Validate scan outputs in GCS |

## License

[Business Source License 1.1](LICENSE) — Free for non-commercial use. Converts to Apache 2.0 on March 19, 2030.
