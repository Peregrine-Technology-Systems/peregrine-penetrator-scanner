# Release Notes

## v0.1.0 — 2026-03-18

### Initial Release

First release of the Automated Web Application Penetration Testing Platform.

#### Features
- **Scan Orchestrator** — Phased execution engine with parallel tool support and fail-forward behavior
- **Scanner Integration** — OWASP ZAP, Nuclei, sqlmap, ffuf, Nikto, Dawnscanner
- **Finding Deduplication** — SHA256 fingerprint-based cross-tool dedup via FindingNormalizer
- **CVE Intelligence** — NVD API v2, CISA KEV, EPSS, OSV enrichment for all findings with CVE IDs
- **AI Analysis** — Claude API integration for finding triage, false positive filtering, executive summaries, adaptive scanning, and Nuclei template generation
- **Report Generation** — JSON, HTML (publication-quality branded template), PDF (via Grover/Puppeteer)
- **Notifications** — Slack webhook and email (authsmtp.com) with scan summaries and PDF attachments
- **Scan Profiles** — YAML-configured quick (~10 min), standard (~30 min), thorough (~2 hr) profiles
- **Docker** — Multi-stage build packaging all 6 security tools + Rails + Chromium
- **GCP Infrastructure** — Pulumi Ruby IaC for Cloud Run Job, Cloud Scheduler, Cloud Storage, Secret Manager
- **CI/CD** — GitHub Actions for test, lint, Docker build, and deployment

#### Infrastructure
- Cloud Run Job: 4 vCPU, 16GB RAM, 3600s timeout
- Cloud Scheduler: configurable cron (default daily 2am UTC)
- Cloud Storage: reports with 90-day lifecycle
- SQLite in-container for per-run state

#### Quality
- 264 tests, 94.64% line coverage
- 0 RuboCop offenses
- All modules under 75 effective lines (SRP)
- UUID primary keys on all models

#### Known Limitations
- Unauthenticated scanning only (authenticated scanning planned for v0.2.0)
- SQLite in-container (Cloud SQL migration planned for future)
- No web UI (CLI/rake task interface only)
- Docker image ~3-5GB due to security tool binaries

### Upgrade Notes
Initial release — no upgrade path.

---

*Versioning follows [Semantic Versioning 2.0.0](https://semver.org/).*
*Format: MAJOR.MINOR.PATCH — breaking.feature.fix*
