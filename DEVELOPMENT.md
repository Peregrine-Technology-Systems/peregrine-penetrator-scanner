# Development Guide

Developer guide for the web application penetration testing platform.

## Prerequisites

- **Ruby 4.0.5** (managed via `chruby`/`rbenv`/`asdf`; the repo pins it in `.ruby-version`)
- **Bundler** (`gem install bundler`)
- **SQLite3** (development database)
- **GCP CLI** (`gcloud`) -- only needed for GCS output and org-native ops

> **Native (non-container).** The scanner runs **natively** — there is no container build of any kind. In production it executes on a single-use VM booted from a pre-baked GCE image (`txn-scanner-app`); see [README → Image Model](README.md#image-model). Report generation (PDF, etc.) lives in a separate Penetrator component, not this repo.

### Security Tools (for local scanning)

In production these are **baked into the `txn-scanner-app` image** (nothing is installed at scan time). For local development, install whichever the profile you're testing needs. The org-native production profile (`reduced`) uses only the baked set:

- **testssl.sh** -- TLS/SSL analysis (in `reduced`)
- **OWASP ZAP** -- DAST (in `reduced`, baseline mode)
- **Nuclei** -- template-based CVE scanning (in `reduced`)
- **trufflehog** -- secret detection (in `reduced`)
- sqlmap, ffuf, Nikto, retire.js, amass -- used by the fuller profiles (`standard`/`thorough`)

## Local Setup

```bash
# Clone the repository
git clone <repo-url>
cd peregrine-penetrator-scanner

# Install dependencies
bundle install

# Wire the git hooks (once per clone — sets core.hooksPath to .githooks).
# Without this, pre-commit checks (RuboCop, tests, coverage) silently don't run.
make hooks

# Migrate the database (Sequel migrations — this is not Rails)
bundle exec rake db:migrate

# Copy environment variables template
cp .env.example .env
# Edit .env with your local values (see Environment Variables section)

# Verify setup
bundle exec rspec
bundle exec rubocop
```

## Development Standards

### TDD: RED -> GREEN -> REFACTOR

All code must be written test-first. The cycle is:

1. **RED** -- Write a failing test that describes the desired behavior
2. **GREEN** -- Write the minimum code to make the test pass
3. **REFACTOR** -- Clean up while keeping tests green

**90% test coverage minimum** is enforced via SimpleCov. Coverage reports are generated in the `coverage/` directory after each test run.

### Single Responsibility Principle (SRP)

Each module/class must have **75 effective lines maximum**. Effective lines exclude blanks, comments, and imports.

### Controllers

Controllers must be **10-15 effective lines maximum**. Keep them thin -- delegate all business logic to models and services.

### Fat Models / Services

Business logic belongs in models (`app/models/`) and service objects (`app/services/`), never in controllers. The service layer handles orchestration, external integrations, and complex operations.

### UUIDs Only

All models use UUID primary keys (`binary_id`). Never use integer IDs. Existing models (Target, Scan, Finding, Report) all follow this pattern.

### Conventional Commits

Every commit message must follow conventional format:

| Type | Version Bump | Usage |
|------|-------------|-------|
| `fix:` | Patch | Bug fixes |
| `feat:` | Minor | New features |
| `feat!:` | Major | Breaking changes |
| `docs:` | None | Documentation only |
| `chore:` | None | Maintenance, deps |

Examples:
```
feat: add Burp Suite scanner integration
fix: correct false positive dedup in FindingNormalizer
docs: update scan profile configuration guide
chore: upgrade nuclei to v3.3.0
```

### Line Counting Standard

Use this command to count effective lines (excludes blanks, comments, and imports):

```bash
grep -v '^\s*$' file.rb | \
  grep -v '^\s*#' | \
  grep -v '^\s*require' | \
  grep -v '^\s*require_relative' | \
  wc -l
```

## Running Tests

```bash
# Run full test suite
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/models/target_spec.rb

# Run with documentation format
bundle exec rspec --format documentation

# Run a specific example by line number
bundle exec rspec spec/services/scan_orchestrator_spec.rb:42

# Check coverage (generated after any rspec run)
open coverage/index.html
```

## Running Linter

```bash
# Check for violations
bundle exec rubocop

# Check specific file
bundle exec rubocop app/services/scan_orchestrator.rb

# Auto-fix violations
bundle exec rubocop -A

# Run in parallel (faster for full codebase)
bundle exec rubocop --parallel
```

## Scan Profiles

Scan profiles are defined in `config/scan_profiles/` as YAML files:

- **reduced** -- the **org-native production profile**; baked-tools-only (testssl + ZAP baseline + Nuclei + trufflehog)
- **quick** -- Fast reconnaissance only
- **standard** -- Balanced coverage
- **thorough** / **deep** -- Full-depth scanning, all tools
- **smoke** / **smoke-test** -- infra validation / canned-findings deploy checks

See [README → Scan Profiles](README.md#scan-profiles) for the per-phase tool matrix.

```bash
# List available profiles with phase details
bundle exec rake scan:profiles

# Validate all profile YAML files
bundle exec rake scan:validate_profiles
```

## Running a Scan Locally

Scans are executed via the `scan:run` rake task with environment variables:

```bash
# Run with defaults (standard profile, localhost target)
bundle exec rake scan:run

# Run with specific profile and target
SCAN_PROFILE=thorough \
TARGET_NAME="My App" \
TARGET_URLS='["https://target.example.com"]' \
bundle exec rake scan:run

# Run against GCS output (findings uploaded to the bucket + control/ artifacts)
GCS_BUCKET=my-scan-bucket \
SCAN_PROFILE=standard \
TARGET_URLS='["https://target.example.com"]' \
bundle exec rake scan:run
```

**Important:** Only scan targets you have explicit written authorization to test.

### Other Useful Rake Tasks

```bash
# Generate Nuclei templates for specific CVEs
bundle exec rake scan:generate_templates CVE_IDS=CVE-2024-1234,CVE-2024-5678
```

## Production Execution (org-native, non-container)

There is no container workflow. In production a scan runs **natively** on a single-use GCE VM booted from the pre-baked `txn-scanner-app` image (runtime + security tools + the app's gems all placed at bake time; nothing installed at scan time), as a dedicated non-root identity, and the VM self-deletes when done. Locally, run the app directly (`bundle exec rake scan:run` / `bin/scan`) with the env vars below — the same entrypoint the VM uses.

Release builds the image via bake-on-tag (`bake.yaml` → infra image pipeline); CI runs natively on the agent (Ruby 4.0.5 via chruby). See [README → Image Model](README.md#image-model) and [CI/CD](README.md#cicd).

## Adding a New Scanner

Follow these steps to integrate a new security tool:

1. **Create the scanner class** at `app/services/scanners/your_scanner.rb`:
   - Extend `ScannerBase`
   - Implement `#execute` to invoke the tool and produce raw output
   - Handle timeouts and tool-specific error conditions

2. **Create the result parser** at `app/services/result_parsers/your_parser.rb`:
   - Parse the tool's output format (JSON, XML, text) into normalized Finding records
   - Map the tool's severity levels to the platform's severity scale
   - Extract CWE/CVE identifiers where available

3. **Add tool configuration to scan profiles**:
   - Update the relevant YAML files in `config/scan_profiles/`
   - Assign the tool to the appropriate phase (discovery, active, or targeted)
   - Set tool-specific options (timeouts, intensity, etc.)

4. **Register in the orchestrator**:
   - Add the scanner to `ScanOrchestrator` so it is invoked during the correct phase

5. **Write specs**:
   - Unit specs for the scanner class with mocked tool execution
   - Unit specs for the result parser with fixture data (sample tool output)
   - Integration spec verifying end-to-end flow
   - Place fixture data in `spec/fixtures/`

## Adding a New Result Parser

1. Create `app/services/result_parsers/your_parser.rb`
2. Implement a `#parse` method that accepts raw tool output and returns an array of normalized finding hashes
3. Map tool-specific fields to the Finding model attributes: `source_tool`, `severity`, `title`, `description`, `url`, `cwe_id`, `cve_id`, `evidence`
4. Write specs with representative fixture data covering normal output, empty results, and malformed input

Existing parsers for reference: `zap_parser.rb`, `nuclei_parser.rb`, `sqlmap_parser.rb`, `ffuf_parser.rb`, `nikto_parser.rb`, `testssl_parser.rb` (all emit the shared `ResultParsers::Contract` shape).

## Git Workflow

```
feature/* --> develop --> staging --> main
```

### Branch Rules

- All branches are protected -- no direct pushes
- Every change requires a pull request connected to a GitHub issue
- **New work = new issue + new branch** -- always create a GitHub issue and a fresh branch before starting
- Never reuse a branch whose PR has been merged
- Feature PRs target `develop`
- Promotion from `develop` to `staging` and `staging` to `main` via PRs

### Workflow

```bash
# Start new work
gh issue create --title "feat: describe the work"
git checkout develop
git pull origin develop
git checkout -b feature/your-feature-name

# Work, commit, push
git add <files>
git commit -m "feat: describe the change"
git push -u origin feature/your-feature-name

# Open PR targeting develop
gh pr create --base develop --title "feat: describe the change"
```

## Project Structure

```
peregrine-penetrator-scanner/
  bin/
    scan                        # Entrypoint — boots, runs ScanOrchestrator, exports to GCS
  lib/
    penetrator.rb               # boot!/boot_services!; logger (JSON when LOG_FORMAT=json); SQLite DB
    models/                     # Sequel ORM models (UUID PKs)
      scan.rb                   # Scan execution records (belongs_to target, has findings)
      finding.rb                # Findings (full probe contract in `data` + promoted columns)
      target.rb                 # Scan targets (urls, auth, scope)
    tasks/
      scan.rake                 # Rake wrapper around the bin/scan flow
  app/
    models/
      scan_profile.rb           # Scan-profile value object (plain class, not Sequel)
    services/                   # Business logic layer
      scan_orchestrator.rb          # Central scan coordinator (phases + SCANNER_MAP)
      scanner_base.rb               # Base class for all probe scanners (shell-out, timeouts, 429)
      scan_results_exporter.rb      # Builds the v2.0 JSON envelope, uploads to GCS
      scan_completion_publisher.rb  # Bus claim-check completion event (completed/failed)
      scan_summary_builder.rb       # Severity/tool summary
      scan_identity.rb              # Scan identity (uuid, transaction_id, trace)
      storage_service.rb            # GCS blob storage (local fallback when GCS_BUCKET unset)
      audit_logger.rb               # Structured audit events
      control_plane_loop.rb         # 30s heartbeat + cancel loop (thread)
      control_flag_reader.rb        # Reads GCS control.json (cancel signal)
      heartbeat_sender.rb           # HTTP callback heartbeat (legacy transport)
      instance_metadata.rb          # GCE metadata (boot image, VM name)
      smoke_checker.rb              # `smoke` profile — tool/secret/GCS availability
      smoke_test_runner.rb          # `smoke-test` profile — canned-findings E2E
      scanners/                     # The 10 probe wrappers (one per tool)
        zap_scanner.rb  nuclei_scanner.rb  sqlmap_scanner.rb  ffuf_scanner.rb
        nikto_scanner.rb  testssl_scanner.rb  retirejs_scanner.rb
        trufflehog_scanner.rb  amass_scanner.rb  schemathesis_scanner.rb
      result_parsers/               # Tool output → probe-output-contract findings
        <one parser per probe>.rb + contract.rb   # (10 parsers + shared contract helper)
      fingerprinters/               # Passive CMS fingerprinting
        fingerprinter_base.rb  fingerprinter_registry.rb
        generic_fingerprinter.rb  wordpress_fingerprinter.rb
      bus/                          # peregrine_bus publish adapter (inert until substrate wired)
        publisher.rb  adapter_env.rb
    assets/images/                  # Logo assets
  config/
    scan_profiles/              # YAML scan profiles (phases → tools)
      quick.yml  standard.yml  thorough.yml
      reduced.yml               # baked-tools-only production pilot profile
      smoke.yml  smoke-test.yml
      deep.yml                  # symlink → thorough.yml
  db/
    sequel_migrations/          # Sequel migrations (per-VM ephemeral SQLite)
    seeds.rb
  .bake/                        # Bake-time contract for the txn-scanner-app image
    install.sh  run.sh  verify.sh  probe-versions.txt
  infra/                        # Pulumi IaC (Ruby) for GCP
    main.rb  Pulumi.yaml
  spec/                         # RSpec test suite
  storage/                      # Per-VM SQLite DB (<APP_ENV>.sqlite3) + scratch
```

## Environment Variables

Reference from `.env.example` -- never commit actual secrets:

Most of these are injected by the org-native launcher; a local run only needs `SCAN_PROFILE` + `TARGET_*`.

| Variable | Description | Default |
|----------|-------------|---------|
| `SCAN_PROFILE` | Scan profile (`quick`/`standard`/`thorough`/`deep`/`reduced`/`smoke`/`smoke-test`) | `standard` |
| `TARGET_NAME` | Name for the scan target | `Example Target` |
| `TARGET_URLS` | JSON array of target URLs | `["https://example.com"]` |
| `SCAN_UUID` | Scan identity (also the `Scan` primary key); launcher-injected | generated |
| `SCAN_MODE` / `ENVIRONMENT` | Environment tag for audit + structured logs | -- |
| `SCAN_TIMEOUT` | Whole-scan wall-clock timeout (seconds) | `3600` |
| `GCS_BUCKET` | GCS bucket for scan output + `control/` artifacts (empty → local fallback) | -- |
| `JOB_ID` | Launcher job id (audit correlation) | -- |
| `CALLBACK_URL` | Optional HTTP heartbeat base (legacy transport, removed at bus cutover) | -- |
| `SCAN_CALLBACK_SECRET` | Bearer token for the callback heartbeat | -- |
| `LOG_FORMAT` | `json` for Cloud Logging (the baked default), else human-readable | -- |
| `LOG_LEVEL` | Logger level | `INFO` |
| `APP_ENV` | App environment (selects the per-VM SQLite DB file) | `development` |
| `BOOT_IMAGE` / `GIT_COMMIT` | Image + commit stamps for the export envelope | metadata |

> **No Slack / SMTP / email / AI / CVE-API env vars.** Those integrations were extracted from the scanner (Slack in #816; AI/CVE enrichment and report generation earlier) — the scanner is a headless probe-runner that emits findings to GCS + the bus. GCS resolves its GCP project from Application Default Credentials / the GCE metadata server, so there is **no** `GOOGLE_CLOUD_PROJECT` env var in the runtime.
