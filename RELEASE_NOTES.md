# Release Notes

## Unreleased

### Cloud Development Environment
- GCP VM-based dev environment (`./cloud/dev` CLI) for remote Docker builds and scans
- 200GB persistent data disk for Docker layer cache, BuildKit cache, and scan results
- Differential tar sync for efficient code transfer to VM
- Auto-idle shutdown after 10 minutes of inactivity
- Separate GCP project (`peregrine-pentest-dev`) with dedicated service account

### CI/CD Pipeline
- Migrated from GitHub Actions to Buildkite (`.buildkite/pipeline.yml`)
- Test and lint run in `ruby:3.2.2` Docker containers on Buildkite agents; Docker image build on staging/main
- Docker builds use registry-based BuildKit cache for speed across agents
- Auto-merge for development → staging promotion PRs
- Manual merge required for staging → main promotion
- Branch protection updated to require Buildkite status checks
- Promotion via GitHub API curl/jq script (no `gh` CLI dependency)
- Force clean checkout to prevent root-owned file conflicts from Docker plugin
- Secrets managed via GCP Secret Manager (`web-app-penetration-test--*` in ci-runners-de)

### Code Quality
- Zero RuboCop offenses across all 94 files (was 33 pre-existing)
- Report generators refactored: extracted MarkdownFormatters, MarkdownSections, MethodologyContent, MarkdownConverter, ReportStyles, ComponentStyles modules
- Scanner base and orchestrator methods extracted for clarity

### Report Versioning
- Reports show version on title page: commit hash for dev/staging, semver for production
- Version displayed in executive summary (all formats) and PDF cover page
- Cloud dev scan passes commit hash as VERSION env var

### Report Fixes
- Fixed PDF generation: removed unused `soul.sty`, switched to DejaVu Sans font (available in container)
- PDF generation now raises error instead of silently saving markdown as `.pdf`
- Added Peregrine logo to HTML report header
- Info-level findings filtered from reports with portal upsell note
- PDF generation raises error on failure instead of saving markdown as .pdf
- Report section renamed from Executive Summary to Metrics; AI summary separate
- Removed duplicate Executive Summary heading (AI text includes its own)
- Prevent heading widowing with needspace in LaTeX template
- Cover and back page: Peregrine gold branding
- Email notification: fixed auth method (`:login`), added 10s timeout

### Scan Reliability
- Rate limiting on all scan profiles (quick: 10 req/s, standard: 8 req/s, thorough: 5 req/s) based on nginx 10 req/s limit
- Heartbeat logging during long-running tool execution (logs elapsed time every 60s)
- AI analysis capped at top 50 findings for triage (prevents hanging on large result sets)

### Docker & Deployment
- Added pandoc + texlive-xetex to Docker image for in-container PDF generation
- Fixed ZAP startup: symlink `/zap` → `/opt/zap` (scripts hardcode `/zap/zap-x.sh`)
- Fixed OWASP ZAP integration: use official ghcr.io image, `/zap/wrk` output directory, python3 symlink, pyyaml dependency
- Updated tool versions: ZAP 2.17.0, Nuclei 3.7.1, sqlmap 1.10.3, ffuf 2.1.0, Nikto 2.6.0
- Fixed Nikto Perl dependencies (`libjson-perl`, `libxml-writer-perl`)
- SecLists wordlists bundled locally via `docker/wordlists/` (avoids clone timeout in Docker build)
- Added Node.js + puppeteer for PDF generation
- GCP Cloud Run Job and Cloud Scheduler deployed (weekly Monday 2am UTC)

### Report Generation
- New Markdown report generator (`ReportGenerators::MarkdownReport`)
- Publication-quality PDF reports via pandoc/xelatex with custom LaTeX template
- Branded title page and back page with Peregrine falcon logo (navy background)
- CONFIDENTIAL watermark at 45 degrees on content pages (not on title/back page)
- Clickable Table of Contents with PDF bookmarks
- Colored section headers, footer rules, project title in footer
- Widow/orphan control, page breaks before major sections
- Test methodology appendix with OWASP Top 10 mapping
- TikZ severity donut chart with color legend on dedicated page
- Clickable CWE references (linked to cwe.mitre.org)
- Clickable CVE references (linked to nvd.nist.gov)
- Detailed findings capped at top 50 per report (full data in JSON)
- Sanitized tool status output and evidence text for LaTeX compatibility
- License changed from MIT to Business Source License 1.1
- TikZ severity donut chart with color legend on dedicated page
- Clickable CWE references (linked to cwe.mitre.org)
- Clickable CVE references (linked to nvd.nist.gov)

### AI Integration
- Fixed Anthropic gem: migrated from `anthropic` to `ruby-anthropic` v0.4+
- Fixed API client to use `access_token` and `messages(parameters:)` interface

### Scanner Fixes
- Fixed `ScannerBase#run_command`: replaced `Open3.capture3(timeout:)` with `Open3.popen3` + `Timeout.timeout` for proper process management
- Fixed ZAP scanner to use `/zap/wrk` output directory and copy results

---

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
