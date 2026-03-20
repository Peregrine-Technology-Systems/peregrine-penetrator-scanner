# Release Notes

## Unreleased

### Bug Fixes
- StorageService falls back to local storage when GCS bucket is inaccessible instead of crashing scan (#139)

### Cloud Scheduler
- Weekly production scan via Cloud Scheduler + Cloud Function (#112)
- Cloud Function launches ephemeral spot VM, self-terminates after scan (#112)
- On-demand production scan via `./cloud/dev scan-prod` (#102)

### Remediation Ticketing
- Auto-create tickets in customer issue trackers for actionable findings (#104)
- Insert-only design: no read access to customer ticketing systems (#104)
- GitHub Issues tracker client with severity labels (#124)
- BigQuery-only dedup: prevents duplicate tickets across scans (#125)
- Configurable per-target: tracker type, repo, min severity (#123)
- Pipeline integration: runs after AI analysis, before report generation (#127)

### Finding History
- BigQuery persistent finding log across all scan runs (#115)
- Separate tables per environment: `scan_findings_dev`, `scan_findings_staging`, `scan_findings_production` (#115)
- Finding lifecycle tracking: first seen, last seen, resolved (#115)
- Ticket columns populated from finding evidence after ticketing (#126)
- BigQuery IAM roles granted to scanner service account (#119)

### Report Improvements
- PDF header shows report run date instead of redundant CONFIDENTIAL (#116)
- Logo transparency fix: gold falcon floats on navy cover (#122)
- Embossed gold peregrine logo on PDF cover and back pages (#108, #91)
- Key Metrics table on page 2 below doughnut chart (#92)
- Removed duplicate Executive Summary heading (#93)
- Prevent heading widowing with needspace in LaTeX template (#94)
- Report section renamed from Executive Summary to Metrics
- Info-level findings filtered from reports with portal upsell note (#72, #77)
- PDF generation raises error on failure instead of saving markdown as .pdf (#75)
- Added Peregrine logo to HTML report header (#76)
- Dev scans store reports locally, no GCS permission errors

### Report Versioning
- Reports show version on title page: commit hash for dev/staging, semver for production (#87)
- Version displayed in executive summary (all formats) and PDF cover page (#87)
- Cloud dev scan passes commit hash as VERSION env var (#87)

### Ephemeral Scan VMs
- Staging scans: auto-triggered by Buildkite after merge to staging, ephemeral VM self-terminates (#99)
- Production scans: on-demand via `./cloud/dev scan-prod`, weekly scheduled via Buildkite cron, spot pricing (~60% savings) (#99, #112)
- Unified startup script (`vm-startup.sh`) with `SCAN_MODE` metadata (dev/staging/production) (#99)
- Secrets pulled from GCP Secret Manager at scan time (#99)
- Results uploaded to GCS, notifications via Slack/email (#99)

### VM Notifications
- Dev VM sends Slack notification on start and auto-shutdown (#100)
- Shutdown notification includes total runtime (e.g., "Runtime: 2h 15m") (#100)
- Fixed shutdown notification: added SLACK_WEBHOOK_URL to VM metadata (#128)

### Cloud Development Environment
- GCP VM-based dev environment (`./cloud/dev` CLI) for remote Docker builds and scans
- 200GB persistent data disk for Docker layer cache, BuildKit cache, and scan results
- Differential tar sync for efficient code transfer to VM
- Auto-idle shutdown after 10 minutes of inactivity (#97)
- Idle-shutdown ignores BuildKit infrastructure container (#97)
- Separate GCP project (`peregrine-pentest-dev`) with dedicated service account

### CI/CD Pipeline
- Migrated from GitHub Actions to Buildkite (`.buildkite/pipeline.yml`) (#86)
- Test and lint run in `ruby:3.2.2` Docker containers on Buildkite agents (#86)
- Docker image built once on development, re-tagged on staging/main (no rebuild) (#81, #86)
- Docker builds use registry-based BuildKit cache for speed across agents (#86)
- Auto-merge for development → staging promotion PRs (#79)
- Manual merge required for staging → main promotion (#80)
- Branch protection updated to require Buildkite status checks (#82)
- Promotion via GitHub API curl/jq script (no `gh` CLI dependency) (#90)
- Fix Docker plugin root-owned file cleanup with chmod after test step (#95)
- Fix clean checkout conflicts with Docker plugin pre-exit hook (#98)
- Secrets managed via GCP Secret Manager (`web-app-penetration-test--*` in ci-runners-de) (#86)

### Code Quality
- Zero RuboCop offenses across all 94 files (was 33 pre-existing) (#85)
- Report generators refactored: extracted MarkdownFormatters, MarkdownSections, MethodologyContent, MarkdownConverter, ReportStyles, ComponentStyles modules
- Scanner base and orchestrator methods extracted for clarity

### Report Generation
- New Markdown report generator (`ReportGenerators::MarkdownReport`)
- Publication-quality PDF reports via pandoc/xelatex with custom LaTeX template (#34)
- Branded title page and back page with Peregrine falcon logo (navy background) (#34, #36)
- CONFIDENTIAL watermark at 45 degrees on content pages (not on title/back page) (#34)
- Clickable Table of Contents with PDF bookmarks (#34)
- Colored section headers, footer rules, project title in footer (#34)
- Widow/orphan control, page breaks before major sections (#34)
- Test methodology appendix with OWASP Top 10 mapping (#34)
- TikZ severity donut chart with color legend on dedicated page (#35)
- Clickable CWE references (linked to cwe.mitre.org) (#36)
- Clickable CVE references (linked to nvd.nist.gov) (#36)
- Detailed findings capped at top 50 per report (full data in JSON) (#36)
- Sanitized tool status output and evidence text for LaTeX compatibility (#36)
- Cover and back page: Peregrine gold branding (#36)

### Scan Reliability
- Rate limiting on all scan profiles (quick: 10 req/s, standard: 8 req/s, thorough: 5 req/s) (#38, #66)
- Heartbeat logging during long-running tool execution (logs elapsed time every 60s) (#53)
- AI analysis capped at top 50 findings for triage (prevents hanging on large result sets) (#66)

### Docker & Deployment
- Added pandoc + texlive-xetex to Docker image for in-container PDF generation (#70)
- Fixed ZAP startup: symlink `/zap` → `/opt/zap` (#46)
- Fixed OWASP ZAP integration: use official ghcr.io image, `/zap/wrk` output directory (#46)
- Updated tool versions: ZAP 2.17.0, Nuclei 3.7.1, sqlmap 1.10.3, ffuf 2.1.0, Nikto 2.6.0 (#7)
- Fixed Nikto Perl dependencies (`libjson-perl`, `libxml-writer-perl`) (#71)
- SecLists wordlists bundled locally via `docker/wordlists/` (avoids clone timeout in Docker build) (#71)
- End-to-end Docker fixes for autonomous PDF generation (#71)

### AI Integration
- Fixed Anthropic gem: migrated from `anthropic` to `ruby-anthropic` v0.4+ (#21)
- Fixed API client to use `access_token` and `messages(parameters:)` interface (#21)

### Scanner Fixes
- Fixed `ScannerBase#run_command`: replaced `Open3.capture3(timeout:)` with `Open3.popen3` + `Timeout.timeout` (#8)
- Fixed ZAP scanner to use `/zap/wrk` output directory and copy results (#9)

### Other
- License changed from MIT to Business Source License 1.1
- Email notification: fixed auth method (`:login`), added 10s timeout (#74)
- Fixed CI workflow triggers on wrong branch name (develop vs development) (#78)
- Removed duplicate lint job from CI workflow (#83)
- Restored 90% test coverage threshold (#84)

---

## v0.1.0 — 2026-03-18

### Initial Release

First release of the Automated Web Application Penetration Testing Platform.

#### Features
- **Scan Orchestrator** — Phased execution engine with parallel tool support and fail-forward behavior (#13)
- **Scanner Integration** — OWASP ZAP, Nuclei, sqlmap, ffuf, Nikto, Dawnscanner (#9, #10, #11, #12)
- **Finding Deduplication** — SHA256 fingerprint-based cross-tool dedup via FindingNormalizer (#14)
- **CVE Intelligence** — NVD API v2, CISA KEV, EPSS, OSV enrichment for all findings with CVE IDs (#20)
- **AI Analysis** — Claude API integration for finding triage, false positive filtering, executive summaries, adaptive scanning, and Nuclei template generation (#21, #22, #23, #24)
- **Report Generation** — JSON, HTML (publication-quality branded template), PDF (via Grover/Puppeteer) (#15, #16, #17)
- **Notifications** — Slack webhook and email (authsmtp.com) with scan summaries and PDF attachments (#19)
- **Scan Profiles** — YAML-configured quick (~10 min), standard (~30 min), thorough (~2 hr) profiles (#6)
- **Docker** — Multi-stage build packaging all 6 security tools + Rails + Chromium (#7)
- **GCP Infrastructure** — Pulumi Ruby IaC for Cloud Run Job, Cloud Scheduler, Cloud Storage, Secret Manager (#26)
- **CI/CD** — GitHub Actions for test, lint, Docker build, and deployment (#25)

#### Infrastructure
- Cloud Run Job: 4 vCPU, 16GB RAM, 3600s timeout (#26)
- Cloud Scheduler: configurable cron (default daily 2am UTC) (#26)
- Cloud Storage: reports with 90-day lifecycle (#18)
- SQLite in-container for per-run state (#5)

#### Quality
- 264 tests, 94.64% line coverage (#4)
- 0 RuboCop offenses (#4)
- All modules under 75 effective lines (SRP)
- UUID primary keys on all models (#5)

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
