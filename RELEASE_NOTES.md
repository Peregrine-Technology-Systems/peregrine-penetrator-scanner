# Release Notes

## Unreleased

## v1.3.1 — 2026-06-30
- fix: `ZapScanner` spawns the baked `zap` shim, not `zap.sh` (#980). The v1.3.0 reduced pilot caught `[zap] No such file or directory - zap.sh` — the org-native image puts `zap` (the exec-shim → zap.sh) on PATH, not `zap.sh` itself. One-word fix; testssl/nuclei/trufflehog already ran native on v1.3.0, ZAP now should too. (#980)
- feat: add `.bake/run.sh` runtime entrypoint for the scan-launcher baked-app path (#995). When a request omits `bootstrap_artifact`, the launcher exports the scan env + owns VM self-delete and runs `/opt/app/.bake/run.sh` (`exec bundle exec bin/scan`) — retires the tarball-overlay. (#995)

## v1.3.0 — 2026-06-29
- feat: emit the probe output contract v2.0 from the scanner (#971). Parsers now build the superset contract finding — polymorphic `location{}` (web/network/file/package), lossless `identifiers[]`, tool-reported `scores{}`, `component{}`, `finding_type`, `tool_check_id`, `evidence` — via a shared `ResultParsers::Contract` builder; `Finding` stores the document in a `data` JSON column (migration `006`) with thin index columns; `ScanResultsExporter` emits the v2.0 envelope (`SCHEMA_VERSION` 1.4 → 2.0). **Lossless wins:** `identifiers[]` preserves every CVE/CWE (retire.js/testssl/nuclei previously kept only the first); trufflehog now captures `file:line:commit`; testssl/network, retire.js/package, and trufflehog/file get typed locations instead of a synthesized URL. Tool-reported `cvss`/`epss` stay in `scores{}`; the Analyzer adds authoritative enrichment downstream (no `kev` emitted by the probe). `spec/contract/probe_contract_spec.rb` now also gates the **real** parser→model→exporter output against the same contract as the synthetic corpus. `raw_ref` deferred (null). Suite 432 green, 95.92%. (#971)

## v1.2.0 — 2026-06-29
- refactor: drive ZAP natively via the `zap.sh` daemon + HTTP API — drop the Docker-era `zap-baseline.py`/`/zap/wrk` (#980). The old `ZapScanner` shelled to ZAP's `docker/` python wrappers (not on PATH in the org-native image; tracked in the infrastructure repo) and assumed the Docker `/zap/wrk` path; both are pre-cutover leftovers. Now starts the `zap.sh` daemon (Java + zap.sh are in the v1.1.1 baked image), runs access→spider→passive (baseline) / +active (full) over the ZAP API, exports `/OTHER/core/other/jsonreport/` (the exact shape `ResultParsers::ZapParser` already reads — parser unchanged), and shuts the daemon down. Removes the upstream-tool-on-PATH dependency for a green `zap.status`. Unit-tested via stubbed ZAP API + daemon process. (#980)
- refactor: thin probe — extract enrichment, dedup, BigQuery, and cost-logging from the scanner (#978). Removes `CveIntelligenceService` + `cve_clients/` (NVD/EPSS/KEV/OSV), `SeverityCvssMapper`, `FindingNormalizer` (dedup — the `Finding` model still computes its own fingerprint), `BigQueryLogger`, and `ScanCostLogger` (BQ-coupled and non-functional in org-native prod; cost attribution is being redesigned envelope-side per #954/#970). Unwires the call sites in `bin/scan`, `lib/tasks/scan.rake`, `scan_orchestrator`, `scan_results_exporter`, `control_plane_loop`, and the orphaned `bq_loaded`/`cve_enrichment_completed` audit actions. Also fixes a **latent production bug**: `storage_service.rb` used `Tempfile` via an ambient `require` from a now-deleted file — added `require 'tempfile'` centrally in `penetrator.rb` (also unbreaks the parser specs that relied on the same ambient require). Analysis (enrichment/dedup) now belongs to the Analyzer; cost + Reporter handled downstream per operator. Suite green (451 examples), coverage 92.84%. (#978)
- style: rubocop-clean the synthetic corpus generator + contract spec for full-tree CI (#971). The local pre-commit lints a narrower scope than CI; moved spec constants to top-level, used `let` for corpus loads, a constant-based matcher to avoid `RSpec/ExpectActual`, and inline-disabled `Naming/MethodParameterName` (the idiomatic finding accumulator) + `Metrics/ModuleLength` (the generator). (#971)
- feat: add a deterministic synthetic finding corpus + contract conformance test (#971). `spec/support/synthetic_corpus.rb` (seeded, reproducible) generates two labelled series under `spec/fixtures/synthetic_corpus/`: **100 realistic** findings across all nine reference probes (with multi-identifier/lossless and exact-duplicate cases) and **30 perturbed** out-of-distribution findings, each tagged `ext.synthetic.perturbation` + `label=escalate` to mark the "exceeds the deterministic DSL — escalate/novel" class for downstream Knowledge-Loop bootstrapping (explicitly synthetic, not ground truth). `spec/contract/probe_contract_spec.rb` asserts the corpus conforms to `docs/probe_contract.md` and doubles as the downstream analysis service's stable contract-test target. (#971)
- docs: add the canonical probe output contract — `docs/probe_contract.md` (#971). Defines the superset finding shape all nine probes (and future first-party probes) emit: a polymorphic `location{}` (web/network/file/package/asset), an open `identifiers[]` list (preserves every CVE/CWE/GHSA/CPE the tool asserts, instead of the flat model keeping only the first), tool-reported `scores` kept separate from a namespaced analysis-service `enrichment{}` block (raw signal never overwritten), `component{}`, `raw_ref` (lossless raw payload pointer), and an `ext` overflow seam. Establishes the flexibility rules (open vocabularies not closed enums; additive-only MINOR / removing-a-populated-field MAJOR; consumers ignore unknown fields) so the contract can evolve without breaking lagging consumers, and the storage rule (document canonical, thin justified column index — same shape for BigQuery `JSON` and a future Postgres `JSONB`). Scanner-owned, architecture-blessed. Doc only — no code change yet. (#971)

## v1.1.2 — 2026-06-29
- docs: README — describe the scanner as a thin **probe** in the Penetrator fleet (#973). Removes stale monolith-era framing (the "Rails app doing everything: scan, analyze, report, notify" lineage table → a one-line lineage note) and reframes the scanner's bounded job as run-tools → normalize to the [probe output contract](docs/probe_contract.md) → export findings to GCS. Moves enrichment, deduplication, prioritization, and reporting to "downstream, out of scope"; fixes factual drift (dropped the unwired OSV from the CVE list, removed BigQuery from the headline pipeline, generic "downstream consumer" instead of naming reporter, pointed the docs table at `probe_contract.md`). Pairs with the analysis extraction — lands with/after enrichment+dedup are removed from the scanner. (#973)

## v1.1.1 — 2026-06-28
- chore: drop never-populated monolith columns `findings.ai_assessment` + `targets.ticket_tracker`/`ticket_config` (#960, PR B). Adds Sequel migration `005_drop_dead_columns`; removes the fields from the `Finding`/`Target` models, the target factory, and the v1.x result envelope (`ScanResultsExporter`). **Envelope bumped 1.3 → 1.4** — classified MINOR per a new `schema_versioning.md` clarification: removing an *always-null / never-populated* field cannot break a consumer (a missing key and an always-`null` key deserialize identically), so it is a MINOR, not a MAJOR. `ai_assessment` was never populated (AI moved to the reporter in v0.3.0). Reporter given a heads-up (peregrine-penetrator-reporter#760); shipped without gating per operator (downstream contract changing anyway). (#960)
- chore: remove monolith/Rails-era dead code + document the real retention policy (#960). The scanner cannot and does not retain or purge scan data — downstream components delete the specific records once delivered to the customer — so the monolith-era retention machinery was dead code. Removes `DataRetentionPurger` (+ spec), `lib/tasks/retention.rake`, `app/services/ticketing_service/` (ticketing extracted to the reporter), `app/views/` (orphaned Rails mailer layouts; no mailers exist), the entire Rails-era `db/migrate/` (superseded by `db/sequel_migrations/`), and the now-unused `retention_purge_completed` audit action. Adds the previously-missing `docs/data_retention_policy.md` stating the policy: scanner retains nothing; downstream deletes post-delivery; only a minimal audit record (site scanned, start/end, scan type) is kept 18 months for SOC 2 — vulnerability data is explicitly excluded. (#960)

## v1.1.0 — 2026-06-28

- feat: scan self-reports its boot image (GCE metadata) in `status.json` + audit events for version traceability (#951). New fail-safe `InstanceMetadata.boot_image` reads `instance/image` from the metadata server (→ `unknown` off-GCE, never raises); `bin/scan` stamps `BOOT_IMAGE` at startup so every audit event and the `#906` `status.json` carry the exact image that produced the result. Closes the release-verification blind spot (no org-side image lookup, which is DRS-walled) — a result is now tied to its image directly instead of inferred. (#951)
- fix: skip-if-tested only skips on tree-identity for promotion artifacts, not feature branches (#944). The "file content identical to <target> — already tested" fast-path trusted tree-identity without confirming the target's CI actually passed — a green-by-deferral silent-OK that let a genuinely-red tree (psych/libyaml) merge through three "green" feature CIs. `test.sh`/`lint.sh` now gate the skip on `sync/*`/`merge/*`/`release/*` (which `promote.yaml` creates only after a green source); feature branches always run their own CI. (#944)
- docs: update `DEVELOPMENT.md` for the org-native cutover (#950) — Ruby 3.2→4.0.5, drop Docker/Docker-Compose prerequisites + the whole Docker Development/DVWA section, fix `rails db:create`→Sequel `rake db:migrate`, remove the gone PDF/Grover/Chromium prereq, document the `reduced` production profile + the baked tool set, and replace the Docker workflow with the native/org-native execution model. (#950)
- docs: make README badges self-updating instead of hand-typed literals that lag/misreport (#952). Release badge → dynamic shields GitHub-release (reads the latest Release live, can't lag); removed the static `coverage 94%+` and `rubocop 0 offenses` badges (they could silently misreport — the live Woodpecker CI badge is the honest pass/fail source for both, since CI enforces the coverage gate + rubocop). (#952)

## v1.0.1 — 2026-06-28
- fix: exclude the dev-only `debug` gem from CI so psych isn't compiled from source (#945). Native CI failed on cold agents: `bundle install` tried to build `psych` (no precompiled linux gem) and aborted on missing `yaml.h`/libyaml (dev CI red: #1446/#1448/#1450). psych is pulled only transitively by the dev-only chain `debug → irb → rdoc → psych`; the production bake already dodges this via `--without development test`, which is why the bake works while CI didn't. Fix mirrors the bake: move `debug` to a `development`-only group and run `BUNDLE_WITHOUT=development bundle install` in `test.sh`/`lint.sh` — CI keeps rspec/rubocop (test group), drops debug, never installs psych. Runtime/test YAML uses ruby's built-in psych. Suite green with the group excluded (543 examples, 0 failures). The durable class-fix (libyaml on the agent image) is tracked in the infrastructure repo; the green-by-deferral skip hole that hid this from feature CI is #944. (#945)
- fix: decouple GCS storage + GCS cancellation reads from `GOOGLE_CLOUD_PROJECT` (#942). `StorageService#gcs_configured?` and `ControlFlagReader.enabled?` gated GCS on `GOOGLE_CLOUD_PROJECT` — but that var's real job is enabling BigQuery. The org-native pilot bootstrap leaves it unset to keep BigQuery off, which silently disabled GCS upload too: `scan_results.json` fell back to local disk and was lost on the single-use VM's self-delete, while the scan still reported `rc=0`/completed (same silent-OK class as #784, one level up — the GCS fail-loud guard never fires because the local branch is taken first). Both now gate on `GCS_BUCKET` alone (the `google-cloud-storage` client resolves the project from ADC/metadata); BigQuery remains independently gated on `GOOGLE_CLOUD_PROJECT`. Surfaced by the v1.0.0 org-native pilot scan. Adds the silent-OK positive-counterpart test (bucket set + project unset → uploads to GCS, never local). (#942)
- docs: README — document the `reduced` profile + baked tool set, refresh badges (#940). Adds `reduced` to the Scan Profiles table (flagged as the current org-native production profile — its tools match what's baked into `txn-scanner-app`); adds a "Baked in txn-scanner-app" column to the Security Tool Stack and the four missing tools (testssl, trufflehog, retire.js, amass); bumps the coverage badge 93%→94%+ (actual 94.36%) and adds `release v1.0.0` + baked-image badges. Docs-only. (#940)
- fix: drop the hand-rolled chruby activation in `test.sh`/`lint.sh` — rely on the agent's automatic ruby selection (#938). Per infra (#927), `/etc/chruby-ci.sh` is sourced via `BASH_ENV` on every CI step and runs `chruby "$(cat .ruby-version)"`; with `.ruby-version`=4.0.5 at repo root, 4.0.5 + bundler are already on PATH. The explicit blocks added in v1.0.0 sourced non-existent paths (`/opt/chruby/share/chruby/chruby.sh`) and never put ruby on PATH, failing native CI in ~1s. Removed; kept the `ruby -v` diagnostic echo. (#938)
- docs: update README for the org-native cutover (#932) — drop Docker/DVWA/`cloud/dev` quickstart, ruby 3.2→4.0.5, replace the Docker Architecture + CI/CD sections with the org-native image model (baked `txn-scanner-app`, bake-on-tag, native CI) and the self-delete/reaper safety model, remove the reporter/backend system-context (one-component framing), drop the removed callback (#906), and add product context (Penetrator product line, SOC 2 Type II, cloud-agnostic). (#932)

## v1.0.0 — 2026-06-28
- fix: activate ruby 4.0.5 explicitly in `test.sh`/`lint.sh` for native CI — the non-interactive Woodpecker step shell doesn't auto-switch chruby on `.ruby-version` (chruby source + `/opt/rubies` PATH fallback, set -e-safe). (#916)
- feat!: org-native cutover — remove Docker entirely (#916). Deletes the Docker image build (`docker/`, `build.yaml`/`build-base.yaml`), the legacy GCP Cloud Function launch (`cloud/`), and the Docker-based deploy/release/smoke workflows; CI now runs **native on the agent** (ruby 4.0.5 via chruby/`.ruby-version`, no `docker run`). Production release is org-native: the version tag fires `bake.yaml` → infra TP baker → `txn-scanner-app` GCE image. Also bumps `rubocop-rspec`→3.x (+`rubocop-factory_bot`, plugins config) for ruby-4.0.5 gem compatibility. (#916)
- fix: complete #906 GCS-only completion in `bin/scan` — drop the two `ScanCallbackService` calls (the service was deleted in #906 but `bin/scan` still referenced it → would `NameError` on the baked image) and write `control/<scan_uuid>/status.json` with `results_path` so the consumer can detect completion (mirrors the rake task). (#906)

## v0.21.1 — 2026-06-23

- chore: clean pre-existing sensitive tokens from tracked files flagged by the pre-publish lint (#922). Allow-markered the public Woodpecker CI server host (status badge + notification links — functional, not secret) in README and the notify scripts; stripped internal cross-repo issue numbers from code comments in `notify-status.sh`, `smoke-test.sh`, and `infra/main.rb` (prose retained). RELEASE_NOTES historical `## vX` citations intentionally left as-is per #773 (editing them dup-headings under `merge=union`). No git-history rewrite — current-files cleanup only. (#922)
- feat: add a pre-publish sensitive-content lint to keep the public repo public-safe (#919). New `scripts/woodpecker/check-sensitive-content.sh` blocks operational/identity/topology tokens (infra hostnames, service-account emails, private IPs, internal storage buckets, internal cross-repo issue refs) from **added lines** — pre-existing content is not re-flagged (diff-scoped: staged / `--range` / `--all` modes; the historical cleanup is a separate pass). Generic patterns are committed; specific internal names live in a gitignored `.sensitive-extra-patterns` (shipped as `.example`) so the lint itself doesn't publish them. Inline `# allow-sensitive: <reason>` escape hatch. Wired into `ci.yaml` (parent-commit-aware range mode, skips safely on shallow) and the pre-commit hook (staged, runs for docs too); 11 bats cases. (#919)
- feat: scanner self-bake contract + Woodpecker dispatch to the infra keyless TP baker (#927). Adds `.bake/install.sh` (bake-time `bundle install --deployment` — vendors gems into the image; runs before the baker's scrub) + `.bake/verify.sh` (post-scrub: ruby + `bin/scan` + `bundle check`, never installs) + `scripts/woodpecker/bake-dispatch.sh` + `.woodpecker/bake.yaml` (on release tag, mints the peregrine-ci-app token and POSTs `repository_dispatch` (event_type=bake-tp) to infra). Produces the gem-complete `txn-scanner-app` GCE image `FROM txn-scanner-base` via GitHub OIDC→`tp-baker` federation — scanner stays on Woodpecker with zero org access, no Docker. Unblocks org-native pilot scans (#916). (#927)
- feat: add `reduced` scan profile YAML (`config/scan_profiles/reduced.yml`: testssl + ZAP baseline + Nuclei + trufflehog — baked-tools-only) and register it in the `Scan` model's profile validation (#916). The org-native baked image carries the placed tool set (no nikto/retire/ffuf pending bakery vendoring), so `reduced` is the runnable profile on `txn-scanner-app` until those tools are baked. (#916)
- chore: bump Ruby 3.2.2→4.0.5, Nuclei 3.7.1→3.9.0, Node 20→22 LTS, sqlite3 ~>1.4→~>2.0, activesupport ~>7.1→~>8.1, rubocop ~>1.62→~>1.75; update Gemfile and base-versions.txt (#901).

- feat: remove ScanCallbackService HTTP completion callback; write results_path to GCS control/{scan_uuid}/status.json on scan completion so orchestrator detects completion via GCS watchdog (#905).
- chore: untrack `CLAUDE.md` and add it to `.gitignore` (#908). The project Claude Code instructions carry internal operating context (architecture, infra references, conventions) and should not be published in this public repo. Removed from git tracking via `git rm --cached` (working-tree file retained so local sessions still read it); `.gitignore` now keeps it untracked.
- fix: correct `Layout/LineEndStringConcatenationIndentation` offense in `retirejs_scanner.rb` that was failing development lint (#910). Introduced by #895's `timeout -k 10` shell-wrapper change; rubocop autocorrect, no behavior change. Was blocking all PRs into development.
- fix: kill entire process group on tool timeout (#895). `Open3.popen3` now spawns with `pgroup: 0` (child gets its own process group, PGID == child PID); `kill_process` sends `-TERM`/`-KILL` (negative = group signal) so Node.js/Python/shell grandchildren are reached. Previously only the direct shell PID was killed, leaving retire.js's Node.js process running indefinitely past its timeout. Also adds shell `timeout -k 10 N` wrappers in `retirejs_scanner.rb` as belt-and-suspenders for the fetch and scan commands.
- fix: enable SQLite WAL mode + busy_timeout in `Penetrator.connect_db` to eliminate `SQLite3::BusyException` under concurrent tool writes (#892). `PRAGMA journal_mode=WAL` shrinks the write-commit window so concurrent writers rarely actually collide; `PRAGMA busy_timeout=5000` retries for up to 5s when they do. Default connection pool preserved — `max_connections: 1` would cause `Sequel::PoolTimeout` in parallel scan phases where each tool thread needs its own connection.
- feat: improve quick scan profile — add testssl (TLS/SSL, 90s) and nikto (misconfig, 90s tuning=123b); move retire.js + trufflehog to parallel phase 1 with testssl; cut Nuclei timeout 300s→150s and raise rate 10→15 req/s to stop burning 5 min with 0 findings; ZAP delay halved 100ms→50ms. Expected wall time ~8 min vs ~6 min previously, but with meaningfully broader coverage. (#889)
- fix: serialize `target_urls` list before passing to `compute_v1.Items` in trigger-scan Cloud Functions (#883). When callers pass `"target_urls": [...]` as a JSON array, Flask's `get_json()` returns a Python list; the code only JSON-serialized when building from the singular `target_url` string. The list hit `compute_v1.Items(value=<list>)` and crashed with `TypeError: bad argument type for built-in operation`. Added `elif isinstance(target_urls, list): target_urls = json.dumps(target_urls)` branch + regression test. (#883)

## v0.21.0 — 2026-06-22

- fix: rubocop autocorrects and Dockerfile.base tool install paths (#51, #50, #47). CI failure on development from PR #874 merge: 53 autocorrectable rubocop offenses across scan_orchestrator + new scanner/parser files. amass v5.1.1 ships as `.tar.gz` not `.zip`; retire.js (NodeSource) installs binary to `/usr/bin/retire` and modules to `/usr/lib/node_modules/` — not `/usr/local/` as originally coded in the COPY stage. (#51, #50, #47)

- feat: add retire.js JavaScript library vulnerability scanner (#51). New `Scanners::RetirejsScanner` + `ResultParsers::RetirejsParser` — fetch-then-scan shape (wget mirrors target HTML+JS to a temp dir, retire.js scans the dir for known-vulnerable library versions). Parser is config-free (retire.js severities are already lowercase strings); `identifiers.CVE[]` and `cwe[]` are arrays — takes first element of each. **Built and tested against real retire.js `--outputformat json` output captured from jQuery 1.12.4** (6 vulnerabilities across 2 CWEs), not a remembered schema. Node.js (v20 LTS via NodeSource) + retire.js added to `Dockerfile.base`. Wired into `SCANNER_MAP` + Phase 3 targeted of standard/thorough/quick profiles. Parser + scanner at 100% per-file coverage; modules 38/38 effective lines (SRP). (#51)

- feat: add trufflehog secret/credential scanner (#50). New `Scanners::TrufflehogScanner` + `ResultParsers::TrufflehogParser` — fetch-then-scan shape (wget mirrors target, trufflehog filesystem-scans for hardcoded secrets). Output is NDJSON (one JSON object per detected secret); severity fixed at `high` for all findings (a leaked credential is always serious regardless of type). Stores only the `Redacted` field from trufflehog (not `Raw`) — security hygiene. `DetectorDescription` (or `DetectorName`) used as title. **Built and tested against real trufflehog `--json` output from PrivateKey detection** (real RSA key generated for test, deleted after fixture capture). trufflehog v3 binary added to `Dockerfile.base`. Wired into `SCANNER_MAP` + Phase 3 targeted of standard/thorough/quick profiles. Parser + scanner at 100% per-file coverage; modules 36/39 effective lines (SRP). (#50)

- feat: add amass v5 subdomain enumeration scanner (#47). New `Scanners::AmassScanner` + `ResultParsers::AmassParser` — two-step v5 protocol (`amass enum` populates OAM database, `amass subs` extracts results). Returns `discovered_urls` (not `findings`) which feeds into `@discovered_urls` in `ScanOrchestrator`, expanding the target surface for subsequent phases. Parser skips `Session Scope` and `FQDN:` header lines, prepends `https://` to each hostname. **Verified against real amass v5.1.1 `subs` output format** (the v5 architecture changed from v4's streaming stdout to an OAM database model — this is the correct two-step invocation). amass v5.1.1 binary added to `Dockerfile.base`. Wired into `SCANNER_MAP` + Phase 0 subdomain_discovery of standard/thorough profiles (before parallel discovery tools so URLs feed subsequent phases). Parser + scanner at 100% per-file coverage; modules 16/37 effective lines (SRP). (#47)

## v0.20.0 — 2026-06-22

- fix: size the post-deploy smoke budget to a cold base-rebuild VM + guard the heartbeat against a missing CALLBACK_URL. On a base-image rebuild every layer SHA changes, so the fresh smoke VM pulls the ENTIRE ~2GB image — observed 548s boot+pull before the scanner started, past the 480s observer budget; the scan itself ran in 2s and exported correctly, so the smoke failed purely on the observer giving up too early. `MAX_WAIT` 480→900 (a ceiling — the poll breaks on first result, so warm runs still return in ~150s; this sizes to real infra time, it does not mask a stall). Also guards `HeartbeatSender#send_heartbeat` to no-op when no CALLBACK_URL is configured (the CI smoke launches via trigger-scan.sh, which sets none) — stops the rescued-but-noisy `connection refused for nil port 80` introduced when #830 dropped the smoke-test stub. Durable fix (decouple infra-boot from scan-time via the scan's status.json lifecycle; migrate scan VMs to the estate-wide baking pipeline so there is no cold pull) tracked separately (#811, infra). (#48)

- feat: add testssl.sh TLS/SSL scanner (#48). New `Scanners::TestsslScanner` (discovery phase, one run per target URL, no `--fast`) + `ResultParsers::TestsslParser` normalizing testssl's flat `--jsonfile` output. Severity mapping is config-driven (`config/testssl_severity_map.yml`, the single control point): `OK`/`DEBUG`/`FATAL` and `ip:"/"` engine/cmdline meta records are dropped as non-findings; CRITICAL/HIGH/MEDIUM/LOW map through, WARN/INFO→info. Handles space-separated multi-CVE fields (first CVE) and `--` finding→id fallback. Wired into `SCANNER_MAP` + the standard/thorough/deep discovery phases (quick stays minimal); testssl.sh + `openssl`/`dnsutils` added to `Dockerfile.base` (git-clone pattern, like nikto/sqlmap). **Built and tested against REAL testssl output captured from the authorized target** (167-record fixture), not a remembered schema — because the canned post-deploy smoke does not exercise real scanners (a parser mismatch would otherwise ship silently). Parser + scanner at 100% per-file coverage; modules 44/27 lines (SRP). (#48)

- chore: sweep stale `peregrine-ci-infrastructure` → `peregrine-infrastructure` references (#773). The repo was renamed; updated the two live citations — `CLAUDE.md` Deploy Trigger Pattern (`peregrine-ci-infrastructure` → `peregrine-infrastructure`) and `scripts/woodpecker/notify-status.sh` (`ci-infrastructure` → `peregrine-infrastructure`). Historical `## vX` RELEASE_NOTES citations left as-is (immutable history; editing them would dup headings under merge=union). (#773)

- chore: unwind scanner-side production-scan scheduling (#829). Deleted the broken out-of-band `weekly-production-scan` Cloud Scheduler job (it 404'd every Monday — targeted `trigger-production-scan`, the real fn is `trigger-scan-production`; config captured before deletion). Removed the never-deployed legacy Cloud-Run-job model from Pulumi — the `pentest-scanner` `CloudRunV2::Job` + `pentest-scanner-schedule` `CloudScheduler::Job` + their `schedule`/`scan_profile` config (no Cloud Run Job was ever live). Production scan **scheduling is owned by the orchestrator** going forward (function-trigger model per infra ruling peregrine-infrastructure); the `trigger-scan-*` Cloud Functions + `vm-scavenger` are retained (the orchestrator triggers scans via `trigger-scan-production`). #829 closed as superseded (#829)

## v0.19.3 — 2026-06-22

- fix: version-bump.sh self-heals the staging→main RELEASE_NOTES misfile (#850). The manual staging→main merge runs `merge=union` with no cleanup pass; under interleaved releases it can push entries OUT of `## Unreleased` INTO a versioned section, emptying Unreleased so the drift guard blocks the tag (required a manual repair during the v0.19.1/v0.19.2 release). When (and only when) the drift guard would otherwise fail, version-bump now reconstructs `## Unreleased` from `origin/staging`'s live Unreleased minus the last tag's released set — restoring misfiled entries and stripping them from the versioned section — then proceeds; if it can't recover from that known source it still fails loud (never guesses a release). New `scripts/reconstruct-release-notes.sh` (+ 5-case bats: incident replay, retroactive-untouched, fail-loud, new-entry, missing-input). Scoped to the drift path only — the happy path is untouched. Known limit: a PARTIAL misfile that leaves Unreleased non-empty won't trigger reconstruct (ships slightly-wrong notes, non-blocking). Per ROBUST_PROMOTE_PATTERN.md §reconstruct-beats-dedup (#850)

## v0.19.2 — 2026-06-21

- fix: version-bump.sh GitHub Release step now converges — retry (3× backoff) + idempotent `ensure_release` (GET-first, re-check after a failed POST) + merge-SHA validation (`^[0-9a-f]{40}$` before tagging) + fail-loud with a copy-paste recovery command. Previously a single un-retried POST only WARNed on failure, so a transient api.github.com flake could strand a tagged release with no GitHub Release — an orphan tag and SOC 2 CC7.2 traceability gap (every tag must have a Release, Rule #8). Tag creation is also idempotent now (converges if it already exists). Per ROBUST_PROMOTE_PATTERN.md §version-bump-must-converge (#841)
- fix: promote.sh adopts Pass 2 RELEASE_NOTES cleanup — the canonical `scripts/cleanup-stale-unreleased.sh` (+ bats suite) strips stale `## Unreleased` entries already present in a versioned section. Without it, merge=union accumulates stale Unreleased entries that collapse into the wrong versioned section → empty Unreleased → no tag (the "#1 cause of stuck releases", Rule #13). Called unconditionally (fail-loud, no silent skip). Pass 3 (repair misfiled) deliberately not adopted — this repo has retroactive RELEASE_NOTES edits that Pass 3 would over-move (#842)
- fix: sync-back.sh no longer double-files just-released entries and no longer uses `git commit --amend`. After the merge it runs `cleanup-stale-unreleased.sh` to subtract from `## Unreleased` any entry version-bump just moved into main's `## vX` section (merge=union left them duplicated → every released entry appeared twice on dev/staging, polluting the next release). The `git commit --amend` (forbidden by global Rule #9 + ROBUST_PROMOTE_PATTERN.md) is replaced with a separate `chore:` commit. Per ROBUST_PROMOTE_PATTERN.md §sync-back (#843)

## v0.19.1 — 2026-06-21

- fix: harden promotion/release merge against GitHub async mergeability (#775). `version-bump.sh`'s mergeability poll now accepts `unstable` as well as `clean` — under Pattern A/B branch protection a non-required check (e.g. CodeQL on the release PR) never blocks the merge, so bailing on `unstable` stranded the release for a check that doesn't gate it (this is what stalled the v0.19.0 release and required a manual recovery). `promote.sh` replaces its single-shot `PUT /merge` — which printed "queued or waiting" and silently exit-0'd on failure, leaving PRs open with no clear error (a silent-OK, the original #775 report) — with the canonical poll (`clean`|`unstable`) + 3-attempt merge retry + fail-loud. Also fixes a `git commit --amend` in `promote.sh`'s Unreleased-dedup (global Rule #9 + ROBUST_PROMOTE_PATTERN.md forbid amend) → separate `chore:` commit. Pattern grounded in `~/.claude/docs/ROBUST_PROMOTE_PATTERN.md` (#775)

- fix: Nikto severity driven from a stable key (test id / OSVDB id) via a maintained `config/nikto_severity_map.yml` lookup, with keyword inference as the unmapped fallback — and every fall-through to the `info` default is now logged (never silent). Closes the silent critical→info downgrade where a reworded upstream message (e.g. "Remote Code Execution" → "arbitrary OS operations") dropped a genuine critical to `info`. The shipped map starts empty (grown deliberately); the immediate behaviour change is observability of mis-maps + the mechanism to pin severities. Regression test asserts a known-critical stays critical via the stable key even when the message would infer `info` (positive broken-state counterpart) (#823)

## v0.19.0 — 2026-06-21

- feat: smoke-test profile POSTs real heartbeat + scan_complete callbacks for the orchestrator loopback (#830). Removed the `SCAN_PROFILE == 'smoke-test'` `stub_mode?` short-circuits in `HeartbeatSender` and `ScanCallbackService` (they suppressed exactly the POSTs the orchestrator's `/smoke-test/full-flow` loopback needs to prove the callback path — a silent-OK), and added the `scan_complete` POST to `bin/scan`'s smoke-test export block (it exited early before the normal callback step ever ran). `enabled?` (CALLBACK_URL presence) is now the sole control: the staging CI smoke launches via `trigger-scan.sh` which sets no CALLBACK_URL, so callbacks stay silent there; the orchestrator/Cloud-Function trigger sets CALLBACK_URL so the loopback POSTs fire. Payload (`gcs_scan_results_path`, `tool_chain`, `cost_data`, `summary`, `duration_seconds`) already matches the orchestrator's `CallbackController` handler verbatim; `status.json` (`{phase, scan_exit_code}`) is already written by `vm-startup.sh`. Contract for the orchestrator: pass `CALLBACK_URL=<host>/callbacks` (we derive `/heartbeat` + `/scan_complete`). Orchestrator wait-for-completion side: pno#358 (#830)

## v0.18.2 — 2026-06-09

- ci: migrate CI pipeline-status notifications to the ci-events Pub/Sub bus (bus-only-emit, ci-infra) and drop Slack — Slack is deprecated (#780). `notify-status.sh` now publishes a `pipeline.status` CloudEvent to `ci-events` as `ci-agent@`; `SLACK_WEBHOOK_URL` removed from all 9 workflows; `version-bump.sh`'s direct Slack message removed. Also fixes the production-smoke env bug surfaced by #808: `smoke-test.sh` passed `$BRANCH` (`main`) to `trigger-scan.sh`, which expects an environment name → "Unknown environment: main"; now passes `IMAGE_TAG` (staging|production). App-level `SlackNotifier` runtime migration tracked as a follow-up (#780)

## v0.18.1 — 2026-06-09

- ci: complete the #767 decoupled production deploy + production smoke (#808). Now that the `peregrine-ci-app` App token has `deployments: write` (infra), `version-bump.sh`'s Deployment POST fires `release.yaml` (`event: deployment`), which retags `scanner:staging → scanner:production` (digest-verified) **and** runs a production smoke. `version-bump.sh` no longer retags `scanner:production` itself (release.yaml owns it). `smoke-test.sh` handles `event: deployment → main`; `smoke-test.yaml` is now staging-only (it depended on the staging-only `deploy`, so it could never smoke `main`). Production is finally smoke-verified on its own deploy, not just by byte-identity with staging (#808)

## v0.18.0 — 2026-06-09

- chore: remove dead code + housekeeping — delete `dawn_scanner`/`dawn_parser` (and specs): wired into `SCANNER_MAP` but in no profile, and it audited the scanner's own gems (`dawn … Penetrator.root`) rather than the target, so it was both dead and architecturally wrong for a DAST tool. Delete the stale root `Dockerfile` (vestigial `rails new` scaffolding — the real image is `docker/Dockerfile`). Untrack + gitignore `spec/examples.txt` (RSpec persistence file that churned every run). Docs (README, ARCHITECTURE, DEVELOPMENT) updated. Also fix a `.githooks/pre-commit` bug: the best-effort local PDF-generation step (`generate-doc-pdf.sh` + the `[ -gt 0 ] && echo` guards) could return non-zero under `set -e`, silently aborting any commit that touched a real `.md` file. Made the whole block non-fatal with `|| true` (#799)
- ci: migrate CI GitHub auth from static `gh_token` PAT to the `peregrine-ci-app` GitHub App (incumbent migration per peregrine-infrastructure/docs/operations/gh-app.md, #779). `promote.yaml`, `version-bump.yaml`, `sync-back.yaml`, and `release.yaml` now fetch the GCS-hosted token wrapper and `eval "$(get-gh-app-installation-token.sh)"` to mint a 1-hour auto-expiring installation token, instead of `from_secret: gh_token`. The static `*--gh-token` SM secret + Woodpecker secret are kept disabled-but-present for the 30-day rollback window, then removed. No `from_secret: gh_token` remains in any workflow (#779)
- fix: smoke observer fails loudly when it can't read the results bucket — the post-deploy smoke runs as `ci-agent@ci-runners-de` on the fleet and polls `gs://…-pentest-reports/scan-results/`. If that SA lacks `storage.objectViewer`, `gsutil ls` is permission-denied and the old `2>/dev/null` swallowed it into a false "No JSON results found" — masking a permission gap as a scan failure (silent-OK). Added a preflight bucket-read check that exits 1 with the actual cause (and points at infra, the matching `objectViewer` grant). With #794, the scan now genuinely writes its result to GCS; this is the observer-side counterpart so a read-access gap can't be misread as a scan failure (#784)
- fix: kill the GCS silent-OK + capture VM scan logs — `StorageService` no longer silently falls back to local disk when GCS is configured but the upload fails. A scan VM's purpose is to export to GCS; the old `WARN … falling back to local storage` wrote results to a container path lost on `--rm` exit while the scan still reported `completed` — a silent-OK that hid lost results for months and is why staging smoke never produced a `scan_results.json`. Now a configured-GCS upload failure raises loudly. Also `bucket(skip_lookup: true)` (don't gate object writes on `storage.buckets.get`), and `vm-startup.sh` uploads `/tmp/scan.log` to `gs://…/vm-results/<vm>/scan.log` unconditionally (the serial console is unreliable and the VM self-destructs, so failures otherwise leave no trace). Per the falcon silent-OK discipline. (#784)
- fix: smoke-test reliability — size the observer budget to the real ephemeral-VM cycle (`MAX_WAIT` 180s→480s). The old 180s left the smoke scan only ~60s after the ~120s VM boot+image-pull, so `cleanup-smoke-vms` killed the VM mid-scan and no result ever landed — the cause of the persistent staging smoke failures once routing/IAM were fixed. Also replace the stale `gsutil ls | tail -1` result selection (which could validate a months-old file) with set-difference detection of *this* scan's fresh output, gated on `metadata.profile == smoke-test` so the deploy step's concurrent standard scan can't be validated by mistake (#784)
- ci: adopt Pattern A branch protection + make `version-bump.sh` enforce_admins-compatible. `version-bump.sh` no longer direct-pushes to `main` — it commits the bump on a `release/vX.Y.Z` branch, opens + API-merges a PR to `main`, and creates the tag via the GitHub API (mirrors peregrine-platform-ioi, incl. the mergeable-race poll + 3-retry guards). Adds committed `scripts/setup-branch-protection.sh` as the source-of-truth artifact for Pattern A (PR required, 0 approvals, `enforce_admins: true`, no required status checks). Applied to `development` + `staging`; `main`'s `enforce_admins` flip is deferred until the new `version-bump.sh` reaches `main` (#787)
- feat: smoke/deploy verification hardening — bake `GIT_COMMIT` into the scanner image (`docker/Dockerfile` + `build.sh`) and emit `scanner_version` (`Penetrator::VERSION`) + `scanner_commit` in the scan envelope `metadata` (additive, schema stays v1.3). `smoke-test.sh` now proves deployed bits: on staging it asserts `scanner_version == cat VERSION` and `scanner_commit == CI_COMMIT_SHA`; on main (retagged image) it asserts both fields are present. `deploy.sh` verifies the production retag (act→verify→alert): re-resolves `scanner:production` and fails loudly if its digest != the promoted staging digest (#786)
- ci: align workflows to current global standards — remove `backend: local` from all 9 `.woodpecker/*.yaml` workflows so steps route to the GCP agent fleet (`ci-agent@ci-runners-de`) instead of the bare d3ci42 droplet; this is the root cause of the persistent staging deploy/smoke-test failures since the fleet migration (#776, #781). `ci.yaml` now also excludes promotion-artifact branches (`merge/*`, `sync/*`, `release/*`) per MUST HAVE Rule #2. `version-bump.sh` guards are subject-anchored (`head -n1`) to avoid skipping a real release on a multi-line body match (identity v0.1.85 pattern), and gain loud drift detection (`exit 1`) when `## Unreleased` is empty while substantive commits exist (#776)
- feat: decouple production deploy from merge — fire GitHub Deployment API as a separate step (#767, cross-repo rollout #1187). `.woodpecker/release.yaml`'s production trigger flipped from `event: push, branch: main` to `event: deployment`. Staging deploy (`.woodpecker/deploy.yaml`) unchanged. `version-bump.sh` POSTs to `/repos/.../deployments` after Release creation; `deploy.sh` updated to map `CI_PIPELINE_EVENT == deployment` to TARGET=main and posts `in_progress` / `success` / `failure` status callbacks against the Deployment record. `GH_TOKEN` added to release.yaml's promote-image step. Reference impl: peregrine-grafana@f7507b4 + peregrine-monitoring@c80e0d3 + peregrine-penetrator-front-end PR#677. Allowlist prerequisite (ci-infrastructure) cleared 2026-04-26.
- fix: `promote.sh` deletes stale remote merge branch before push — avoids non-fast-forward on close-and-retry (ci-infrastructure)
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
