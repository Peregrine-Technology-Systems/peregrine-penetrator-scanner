# Development Guide

Developer guide for the web application penetration testing platform.

## Prerequisites

- **Ruby 4.0.5** (managed via `chruby`/`rbenv`/`asdf`; the repo pins it in `.ruby-version`)
- **Bundler** (`gem install bundler`)
- **SQLite3** (development database)
- **GCP CLI** (`gcloud`) -- only needed for GCS/BigQuery export and org-native ops

> **No Docker.** The scanner runs **natively** — there is no `Dockerfile`, `docker-compose`, or container build. In production it executes on a single-use VM booted from a pre-baked GCE image (`txn-scanner-app`); see [README → Image Model](README.md#image-model). Report generation (PDF, etc.) lives in a separate Penetrator component, not this repo.

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

# With AI analysis enabled
ANTHROPIC_API_KEY=your-key-here \
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

## Production Execution (org-native, no Docker)

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

Existing parsers for reference: `zap_parser.rb`, `nuclei_parser.rb`, `sqlmap_parser.rb`, `ffuf_parser.rb`, `nikto_parser.rb`, `dawn_parser.rb`.

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
  app/
    controllers/          # Thin controllers (10-15 lines max)
    models/               # Domain models with UUID PKs
      target.rb           # Scan targets (name, urls, auth, scope)
      scan.rb             # Scan execution records
      finding.rb          # Vulnerability findings
      report.rb           # Generated reports
      scan_profile.rb     # Scan profile value object
    services/             # Business logic layer
      scan_orchestrator.rb      # Central scan coordinator
      scanner_base.rb           # Base class for all scanners
      finding_normalizer.rb     # SHA256 fingerprint dedup
      cve_intelligence_service.rb  # NVD/CISA/EPSS/OSV enrichment
      ai_analyzer.rb            # Claude API triage + summary
      report_generator.rb       # JSON/HTML/PDF generation
      notification_service.rb   # Slack + email notifications
      storage_service.rb        # GCS/local file storage
      nuclei_template_generator.rb  # Custom Nuclei templates
      scanners/           # Tool-specific scanner implementations
        zap_scanner.rb
        nuclei_scanner.rb
        sqlmap_scanner.rb
        ffuf_scanner.rb
        nikto_scanner.rb
        dawn_scanner.rb
      result_parsers/     # Tool output normalization
        zap_parser.rb
        nuclei_parser.rb
        sqlmap_parser.rb
        ffuf_parser.rb
        nikto_parser.rb
        dawn_parser.rb
      ai/                 # AI analysis components
        claude_client.rb
        executive_summarizer.rb
        finding_triager.rb
      cve_clients/        # CVE intelligence API clients
        nvd_client.rb
        epss_client.rb
        kev_client.rb
        osv_client.rb
      notifiers/          # Notification channel implementations
        slack_notifier.rb
        email_notifier.rb
      report_generators/  # Report format implementations
        json_report.rb
        html_report.rb
        pdf_report.rb
        helpers.rb
    views/
      reports/
        scan_report.html.erb   # HTML report template
  config/
    scan_profiles/        # YAML scan configurations
      reduced.yml           # org-native production profile (baked-tools-only)
      quick.yml
      standard.yml
      thorough.yml
  custom_templates/
    nuclei/               # Custom Nuclei templates
  db/                     # Migrations (SQLite)
  .bake/                  # Bake-time contract for the txn-scanner-app image (install.sh + verify.sh)
  infra/                  # Pulumi IaC (Ruby) for GCP
    main.rb
    Pulumi.yaml
  lib/
    tasks/
      scan.rake           # Rake tasks for scan execution
  spec/                   # RSpec test suite
  storage/
    reports/              # Local report storage
```

## Environment Variables

Reference from `.env.example` -- never commit actual secrets:

| Variable | Description | Default |
|----------|-------------|---------|
| `SCAN_PROFILE` | Scan profile to use | `standard` |
| `TARGET_NAME` | Name for the scan target | `Example Target` |
| `TARGET_URLS` | JSON array of target URLs | `["https://example.com"]` |
| `GOOGLE_CLOUD_PROJECT` | GCP project ID | -- |
| `GCS_BUCKET` | GCS bucket for report storage | `pentest-reports` |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL | -- |
| `SMTP_HOST` | SMTP server hostname | `mail.authsmtp.com` |
| `SMTP_PORT` | SMTP server port | `2525` |
| `SMTP_USERNAME` | SMTP authentication username | -- |
| `SMTP_PASSWORD` | SMTP authentication password | -- |
| `SMTP_FROM` | Sender email address | `pentest@peregrine-tech.com` |
| `NOTIFICATION_EMAIL` | Recipient for scan reports | `security@peregrine-tech.com` |
| `ANTHROPIC_API_KEY` | Claude API key for AI analysis | -- |
| `NVD_API_KEY` | NVD API key for CVE lookups | -- |
