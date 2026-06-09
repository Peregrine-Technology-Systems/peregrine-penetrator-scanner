# Release Notes

## Unreleased

- chore: remove dead code + housekeeping — delete `dawn_scanner`/`dawn_parser` (and specs): wired into `SCANNER_MAP` but in no profile, and it audited the scanner's own gems (`dawn … Penetrator.root`) rather than the target, so it was both dead and architecturally wrong for a DAST tool. Delete the stale root `Dockerfile` (vestigial `rails new` scaffolding — the real image is `docker/Dockerfile`). Untrack + gitignore `spec/examples.txt` (RSpec persistence file that churned every run). Docs (README, ARCHITECTURE, DEVELOPMENT) updated. Also fix a `.githooks/pre-commit` bug: the best-effort local PDF-generation step (`generate-doc-pdf.sh` + the `[ -gt 0 ] && echo` guards) could return non-zero under `set -e`, silently aborting any commit that touched a real `.md` file. Made the whole block non-fatal with `|| true` (#799)
- ci: migrate CI GitHub auth from static `gh_token` PAT to the `peregrine-ci-app` GitHub App (incumbent migration per peregrine-infrastructure/docs/operations/gh-app.md, #779). `promote.yaml`, `version-bump.yaml`, `sync-back.yaml`, and `release.yaml` now fetch the GCS-hosted token wrapper and `eval "$(get-gh-app-installation-token.sh)"` to mint a 1-hour auto-expiring installation token, instead of `from_secret: gh_token`. The static `*--gh-token` SM secret + Woodpecker secret are kept disabled-but-present for the 30-day rollback window, then removed. No `from_secret: gh_token` remains in any workflow (#779)
- fix: smoke observer fails loudly when it can't read the results bucket — the post-deploy smoke runs as `ci-agent@ci-runners-de` on the fleet and polls `gs://…-pentest-reports/scan-results/`. If that SA lacks `storage.objectViewer`, `gsutil ls` is permission-denied and the old `2>/dev/null` swallowed it into a false "No JSON results found" — masking a permission gap as a scan failure (silent-OK). Added a preflight bucket-read check that exits 1 with the actual cause (and points at infra#3502, the matching `objectViewer` grant). With #794, the scan now genuinely writes its result to GCS; this is the observer-side counterpart so a read-access gap can't be misread as a scan failure (#784)
- fix: kill the GCS silent-OK + capture VM scan logs — `StorageService` no longer silently falls back to local disk when GCS is configured but the upload fails. A scan VM's purpose is to export to GCS; the old `WARN … falling back to local storage` wrote results to a container path lost on `--rm` exit while the scan still reported `completed` — a silent-OK that hid lost results for months and is why staging smoke never produced a `scan_results.json`. Now a configured-GCS upload failure raises loudly. Also `bucket(skip_lookup: true)` (don't gate object writes on `storage.buckets.get`), and `vm-startup.sh` uploads `/tmp/scan.log` to `gs://…/vm-results/<vm>/scan.log` unconditionally (the serial console is unreliable and the VM self-destructs, so failures otherwise leave no trace). Per the falcon silent-OK discipline. (#784)
- fix: smoke-test reliability — size the observer budget to the real ephemeral-VM cycle (`MAX_WAIT` 180s→480s). The old 180s left the smoke scan only ~60s after the ~120s VM boot+image-pull, so `cleanup-smoke-vms` killed the VM mid-scan and no result ever landed — the cause of the persistent staging smoke failures once routing/IAM were fixed. Also replace the stale `gsutil ls | tail -1` result selection (which could validate a months-old file) with set-difference detection of *this* scan's fresh output, gated on `metadata.profile == smoke-test` so the deploy step's concurrent standard scan can't be validated by mistake (#784)
- ci: adopt Pattern A branch protection + make `version-bump.sh` enforce_admins-compatible. `version-bump.sh` no longer direct-pushes to `main` — it commits the bump on a `release/vX.Y.Z` branch, opens + API-merges a PR to `main`, and creates the tag via the GitHub API (mirrors peregrine-platform-ioi, incl. the mergeable-race poll + 3-retry guards). Adds committed `scripts/setup-branch-protection.sh` as the source-of-truth artifact for Pattern A (PR required, 0 approvals, `enforce_admins: true`, no required status checks). Applied to `development` + `staging`; `main`'s `enforce_admins` flip is deferred until the new `version-bump.sh` reaches `main` (#787)
- feat: smoke/deploy verification hardening — bake `GIT_COMMIT` into the scanner image (`docker/Dockerfile` + `build.sh`) and emit `scanner_version` (`Penetrator::VERSION`) + `scanner_commit` in the scan envelope `metadata` (additive, schema stays v1.3). `smoke-test.sh` now proves deployed bits: on staging it asserts `scanner_version == cat VERSION` and `scanner_commit == CI_COMMIT_SHA`; on main (retagged image) it asserts both fields are present. `deploy.sh` verifies the production retag (act→verify→alert): re-resolves `scanner:production` and fails loudly if its digest != the promoted staging digest (#786)
- ci: align workflows to current global standards — remove `backend: local` from all 9 `.woodpecker/*.yaml` workflows so steps route to the GCP agent fleet (`ci-agent@ci-runners-de`) instead of the bare d3ci42 droplet; this is the root cause of the persistent staging deploy/smoke-test failures since the fleet migration (#776, #781). `ci.yaml` now also excludes promotion-artifact branches (`merge/*`, `sync/*`, `release/*`) per MUST HAVE Rule #2. `version-bump.sh` guards are subject-anchored (`head -n1`) to avoid skipping a real release on a multi-line body match (identity v0.1.85 pattern), and gain loud drift detection (`exit 1`) when `## Unreleased` is empty while substantive commits exist (#776)
- feat: decouple production deploy from merge — fire GitHub Deployment API as a separate step (#767, cross-repo rollout #1187). `.woodpecker/release.yaml`'s production trigger flipped from `event: push, branch: main` to `event: deployment`. Staging deploy (`.woodpecker/deploy.yaml`) unchanged. `version-bump.sh` POSTs to `/repos/.../deployments` after Release creation; `deploy.sh` updated to map `CI_PIPELINE_EVENT == deployment` to TARGET=main and posts `in_progress` / `success` / `failure` status callbacks against the Deployment record. `GH_TOKEN` added to release.yaml's promote-image step. Reference impl: peregrine-grafana@f7507b4 + peregrine-monitoring@c80e0d3 + peregrine-penetrator-front-end PR#677. Allowlist prerequisite (ci-infrastructure#1188) cleared 2026-04-26.
- fix: `promote.sh` deletes stale remote merge branch before push — avoids non-fast-forward on close-and-retry (ci-infrastructure#1089)
- ci: remove `failure: ignore` from smoke-test step — smoke-test failures no longer mask as pipeline success. `cleanup-smoke-vms` still runs via `when.status` so VMs get cleaned up even on failure (#762)

## v0.17.2 — 2026-04-27

## v0.17.1 — 2026-04-20
- fix: version-bump.sh re-seeds `## Unreleased` and creates a GitHub Release per tag — previously orphan tags accumulated and Unreleased items piled under older versions. Historical v0.16.1–v0.16.7 backfilled from git log in the same PR (#753)

## v0.17.0 — 2026-04-19

## v0.16.6 — 2026-04-09
- fix: version-bump.sh re-seeds `## Unreleased` and creates a GitHub Release per tag — previously orphan tags accumulated and Unreleased items piled under older versions; historical v0.16.2/4/6/7 still empty pending manual backfill (#753)
- fix: version-bump.sh re-seeds `## Unreleased` and creates a GitHub Release per tag — previously orphan tags accumulated and Unreleased items piled under older versions. Historical v0.16.1–v0.16.7 backfilled from git log in the same PR (#753)

- feat: opt-in Nuclei auto-templates when WordPress is detected — default off, enable per-profile with `auto_templates: true` on the nuclei tool config (#741)
- feat: emit cms_inventory in scan envelope + bump SCHEMA_VERSION to 1.3 (#740)
- feat: WordPress CMS detector — generator meta + wp-content/wp-includes + wp-json REST + readme/wp-login probes with weighted confidence scoring and core-version extraction (#738)
- feat: fingerprinter framework (base class, registry, generic fallback) + orchestrator hook writes `cms_inventory` into `scan.summary` (#737)

## v0.16.7 — 2026-04-12

- fix: callback URL path doubled — `/callbacks/callbacks/heartbeat` — treat CALLBACK_URL as base, append only endpoint suffix; fix vm-startup.sh auth header (#728)
- fix: CI workflow runs on on-demand VMs to avoid spot preemption (#726)
- fix: scan VMs fail on zone exhaustion — multi-region zone fallback (9 zones), structured 503 on total failure (#710)

- fix: scan VMs preempted immediately — SPOT pricing now opt-in, defaults to on-demand for reliability (#719)

## v0.16.5 — 2026-04-09

- fix: VM startup failure observability — Cloud Function writes vm-created marker to GCS, EXIT trap sends failure callback to orchestrator (#711)
- fix: revert promote depends_on deploy — deploy only runs on staging, was blocking dev→staging promotion (#691)

## v0.16.4 — 2026-04-09

- fix: heartbeat stops updating during long Nuclei scans — chunked stdout reading yields GIL to heartbeat thread (#697)
- fix: sync-back PRs no longer block unrelated promotions — guard scoped to target base branch (#698)

## v0.16.3 — 2026-04-09

- fix: make callback_url a required parameter from trigger call — reject with 400 if missing (#695, #691)
- fix: pre-commit hook excludes spec/ from code files — lint was being skipped (#683, #690)

## v0.16.2 — 2026-04-06

- fix: BQ cost insert fails silently on schema mismatch — schema integrity smoke tests added (#661, #651)

## v0.16.1 — 2026-04-06

- fix: heartbeat stops updating during long Nuclei scans — cache StorageService, isolate tick operations with independent timeouts (#661)

## v0.16.0 — 2026-04-06

- feat: tool chain in GCS export and callback payload — planned tools, per-tool timing, exit codes, findings count; schema v1.2 (#663)
- refactor: reduce redundant object instantiation and code duplication across services (#653)

## v0.15.2 — 2026-04-05

- feat: tool chain in GCS export and callback — planned tools, per-tool timing, exit codes, findings count; schema v1.2 (#663)
- fix: empty SCAN_UUID breaks GCS control paths — fall back to generated UUID instead of empty string (#659)
- fix: promote pipeline stuck running — notify-status must run on success too for Woodpecker to finalize workflow (#654)
- refactor: reduce redundant object instantiation and code duplication across services (#653)
- fix: comprehensive scan cost tracking — use SCAN_UUID from trigger as scan ID, track NVD API calls, GCS uploads (results + heartbeats + markers + dead letters), and BigQuery streaming insert bytes (#651)
- fix: VM self-termination hardening — timeout on GCS upload, fallback shutdown on gcloud delete failure (#650)
- fix: Slack notification sequence — tag message is informational gray, not gold celebration (#367)
- feat: observable post-scan lifecycle — GCS status.json + Slack for upload/terminate phases (#630)
- docs: comprehensive architecture documentation with Mermaid diagrams (#621)
- fix: populate findings_count per tool in tool_statuses JSON for reporter Appendix A (#541)

## v0.15.1 — 2026-04-04

## v0.14.1 — 2026-04-04

- fix: redirect docker output to log file — prevents GCE script runner crash on long lines (#631)

## v0.14.0 — 2026-04-04

- docs: update README and CLAUDE.md for v0.13.5 VM safety system (#620)
- fix: ZAP deduplicates to unique origins — prevents zombie process on multi-URL scans (#625)

## v0.13.5 — 2026-04-03

- fix: staging scans target correct URL (auxscan.app, not auxscan.stage) — fixes ZAP 600s timeout (#595)
- fix: preflight reachability check aborts scan on unreachable target — 10s fail vs 600s per tool (#600)
- feat: GCS heartbeat every 30s — scan progress observable via control/{uuid}/heartbeat.json (#601)
- feat: heartbeat-aware scavenging — kills stuck VMs with stale heartbeat, soft max reduced to 10m (#602)
- feat: Slack notification on scan start with target, profile, scan ID (#603)
- fix: abort scan on critical tool failure — first-tool or connection errors terminate scan immediately (#604)
- fix: add timeout wrapper to cloud/lib/vm-startup.sh — matches scheduler version, prevents hung scans (#605)

## v0.13.4 — 2026-04-03

- fix: Cloud Function health endpoints use HTTP method guard — GET always returns health, POST triggers scan (#575)
- fix: Cloud Function Python tests use Flask test client instead of MagicMock, fix broken assertions (#575)
- feat: add Cloud Function Python tests to CI pipeline (#576)
- feat: Cloud Function deployment script with post-deploy health verification (#577)
- feat: smoke test verifies GET /health before triggering scan (#577)
- fix: smoke tests verify scan completion status and smoke-test checks, not just GCS artifact existence (#506)

## v0.13.2 — 2026-04-02

- chore: promotion pipeline uses local merge branch — eliminates RELEASE_NOTES conflicts and cascading version bumps (#578)
- fix: sync-back.sh uses local merge branch — same pattern as promote.sh (#582)

## v0.13.0 — 2026-04-02

## v0.3.1 — 2026-03-23

- fix: cleanup stale smoke test VMs after every smoke-test pipeline run (#520)
- fix: add 1-hour timeout to docker run preventing hung scans from orphaning VMs (#547)
- fix: scavenger Cloud Function OIDC auth — add run.invoker role and explicit audience (#547)
- fix: scavenger alerts Slack on failure instead of silently swallowing errors (#547)
- fix: smoke-test VMs exit immediately after GCS export — skip BQ, callback, notifications (#547)
- feat: add /health endpoint to vm-scavenger and trigger Cloud Functions (#550)

- feat: populate CVSS scores, vectors, and EPSS data per finding (#521)
- feat: extract CVSS score, vector, and EPSS from Nuclei template metadata (#523)
- feat: add CVSS vector extraction to NVD client (#524)
- feat: wire CveIntelligenceService into ScanOrchestrator — enriches findings after normalization (#525)
- feat: severity-to-CVSS mapper for findings without CVE IDs (#526)
- feat: add cvss_vector to scan results JSON export and BigQuery schema (#527)
- feat: add cvss_vector column to findings table (#522)
- chore: bump scan results schema version from 1.0 to 1.1
- feat: smoke test suite exercising all sub-library integrations (#529)
- fix: SQL NULL handling in non-CVE finding query — `WHERE IN (NULL)` doesn't match NULL (#529)

## v0.10.7 — 2026-03-29

- feat: trigger_scan Cloud Function accepts request params for Reporter dispatch (#374)
- feat: add `deep` scan profile as alias for `thorough` (Reporter API compatibility)
- fix: sync scheduler vm-startup.sh with authoritative cloud/lib/vm-startup.sh (control plane env vars)
- feat: smoke test script for trigger_scan Cloud Function deployment verification (#413)
- feat: per-environment Cloud Functions — trigger_development, trigger_staging, trigger_production (#427)
- fix: use `bundle exec bin/scan` in Dockerfile CMD and vm-startup.sh — gems in vendor/bundle require bundler (#443)
- chore: remove legacy trigger-production-scan Cloud Function (#434)
- fix: Target model defaults auth_type in before_validation, not before_create — Sequel validates before hooks (#442)
- fix: Scan model defaults status to 'pending' in before_validation (#502)
- feat: skip-CI guard for promotion and sync-back merges with identical code trees (#457)
- fix: version-bump.sh guards for sync-back commits and empty Unreleased — prevents infinite bump loop (#474)
- fix: Docker image promotion uses digest instead of tag — prevents stale production images (#482)
- fix: CI pipeline guarantees production image contains main branch code — build verification, digest pinning, SHA tagging (#484)
- fix: derive heartbeat URL from callback_url — reporter_base_url no longer needed (#512)

- Control plane: HeartbeatSender POSTs liveness to reporter every 30s with progress (#376)
- Control plane: ControlPlaneLoop background thread combines heartbeat + cancel checks (#376, #378)
- Control plane: Job ID passthrough in heartbeats and callbacks (#379)
- Control plane: Callback URL passthrough with job_id in payload (#377)
- Control plane: ControlFlagReader checks GCS control.json for cancel signals (#378)
- Orchestrator checks cancelled? between phases/tools, marks scan cancelled on signal
- vm-startup.sh: add JOB_ID and REPORTER_BASE_URL env vars, remove stale SMTP/Anthropic vars
- Smoke-test profile: canned findings for end-to-end control plane verification in <30s (#380)
- Reliability: scan-level hard timeout via SCAN_TIMEOUT env var, default 3600s (#381)
- Reliability: callback dead letter — writes callback_pending.json to GCS on retry exhaustion (#383)
- Reliability: scan_started.json marker written to GCS on scan start (#384)
- docs: comprehensive ARCHITECTURE.md with Mermaid diagrams — scan flow, control plane protocol, VM lifecycle, data model, reliability guarantees
- docs: README overhaul with Mermaid diagrams, full documentation index, updated metrics
- PDF generation is local-only (not committed to public repo), uses Peregrine branded LaTeX template
- Deploy smoke test: staging/production only, stubs reporter calls, validates baked image on ephemeral VM (#396)
- docs: remove stale DEPLOYMENT.md, DESIGN.md, data_flow.md, separation_of_duties.md (superseded by ARCHITECTURE.md)
- docs: rewrite SECURITY_ARCHITECTURE.md for Sequel, Woodpecker CI, ephemeral VMs, control plane security
- docs: add control plane audit events to audit_logging.md

- Fix: sync-back replaces RELEASE_NOTES from main instead of merging — eliminates duplicate headings and stale entries (#343, #341, #342)
- Add pre-push hook with full test suite, 90% coverage gate, and RuboCop enforcement (#351)
- Fix: pre-commit hook treats .sh files as code, not docs-only (#296)
- Slack error notifications: immediate alerts for rate limiting (429) and tool failures with debounce (#52)
- E2E integration test: validates full pipeline (scan → normalize → dedup → JSON export) with DVWA docker-compose (#28)
- Fix: sync-back fetches main branch before reading RELEASE_NOTES — fixes failure on tag-triggered pipelines

- Hybrid Docker model: dev clones at boot, staging builds baked image, prod re-tags (#276, #286, #309)
- CI enforces RELEASE_NOTES.md update when code files change (#309)
- Scheduler vm-startup.sh updated to APP_ENV and bin/scan (#309)
- VERSION file (semver) — single source of truth, read by `Penetrator::VERSION` (#290, #309)
- Automated version bump on main merge: RELEASE_NOTES, git tag, Docker image tag (#290, #309)
- Slack status notifications: env-specific colors, clickable commits, production header (#309)
- CI enforces 90% minimum test coverage gate (#295, #309)
- Fix: promote uses GitHub Compare API instead of git rev-list (#298, #309)
- Fix: full clone depth for build and version-bump pipelines (#298, #309)
- Fix: version-bump and deploy run independently on main (#302, #309)
- Fix: deploy waits for Docker build on staging (#311, #309)
- Fix: git push auth for version-bump and sync-back (#314, #309)

## v0.3.0 — 2026-03-23

Major refactor: stripped scanner to its core responsibility. Report generation, AI analysis, ticketing, and email notifications extracted to dedicated services (reporter, backend).

### Architecture — Separation of Duties
- **Removed**: Report generation (JSON/HTML/Markdown/PDF), AI analysis (Claude API), ticketing (GitHub Issues), email notifications, Nuclei template generator (#245, #277)
- **Removed gems**: grover, ruby-anthropic, mail — scanner now has 15 gems (was 38 under Rails)
- **Removed Docker deps**: chromium, nodejs, npm, pandoc, texlive, puppeteer — image ~1GB smaller
- **Scanner now does**: scan orchestration → CVE enrichment → JSON export to GCS → BigQuery logging → cost tracking → callback → Slack
- See #278 for full inventory of removed code

### Rails → Sequel Migration
- Replaced Rails 7.1 with Sequel ORM + plain Ruby CLI (`bin/scan`) (#258, #268)
- Boot time: <1s (was 3-5s), RAM: ~80MB (was ~300MB), gems: 15 (was 38)
- Fresh Sequel migrations for targets, scans, findings (SQLite)
- `spec/sequel_helper.rb` replaces `spec/rails_helper.rb` with DatabaseCleaner-sequel
- All `Rails.root` → `Penetrator.root`, `Rails.logger` → `Penetrator.logger`

### CI/CD — Woodpecker Migration
- Migrate from Buildkite to self-hosted Woodpecker CI (#270, #275)
- Pipelines: ci, build, deploy, promote, smoke-test, sync-back
- Docker-wrapped test/lint steps (agent-independent)
- Eliminated Buildkite concurrency throttling

### Pipeline Fixes (#271-274)
- Idempotent migrations via `Sequel::Migrator.is_current?` guard
- Replace `rubocop-rails` with `rubocop-sequel` in lint config
- Fix Sequel dataset `.size` calls (datasets have `.count`, not `.size`)
- Fix serialization in-place mutation bug in TicketingService (use `.merge`)
- Fix `findings_dataset` vs cached `findings` association in specs

### Quality
- 389 specs, 0 failures, 94.96% coverage, 0 RuboCop offenses
- 20 focused open issues (was 50+) — 18 closed, 13 transferred to reporter repo

### Features
- Scan cost tracking: ScanCostLogger logs per-scan cost metrics (VM runtime, tokens, API calls, GCS bytes) to BigQuery `scan_costs` table (#187)
- Scan completion callback: ScanCallbackService POSTs scan summary and cost data to backend API (#186)

### Bug Fixes
- Pass TARGET_NAME env var through scan VMs (#203)
- StorageService falls back to local storage when GCS inaccessible (#139)
- Pass SCAN_MODE env var to Docker in scan VMs (#134)
- Orphan VM scavenger: auto-delete scan VMs older than 30 minutes (#146)
- Scan VMs pull environment-tagged Docker images (#148)
- Repo renamed to `peregrine-penetrator-scanner` (#150, #247)
- Auto-assign repo owner as reviewer on staging→main promotion PRs (#161)

### Cloud Scheduler
- VM scavenger Cloud Function: runs every 10 min, SSH liveness check before deleting orphaned VMs, 4-hour hard max, detailed Slack notifications (#195, #156)
- Self-terminate error logging: failures are now logged instead of silently swallowed, scavenger referenced as fallback (#195)
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
- Secrets managed via GCP Secret Manager (`peregrine-penetrator--*` in ci-runners-de) (#86)

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
