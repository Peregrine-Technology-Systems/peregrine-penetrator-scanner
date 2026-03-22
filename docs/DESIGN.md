# Design Document: Web Application Penetration Testing Platform

**Version:** 1.0
**Last Updated:** 2026-03-18
**Status:** Active Development

---

## Table of Contents

1. [System Overview and Goals](#system-overview-and-goals)
2. [Architecture](#architecture)
3. [Phased Scan Execution Model](#phased-scan-execution-model)
4. [Data Model Design](#data-model-design)
5. [Service Layer Design](#service-layer-design)
6. [AI Assessment Layer](#ai-assessment-layer)
7. [CVE Intelligence Layer](#cve-intelligence-layer)
8. [Report Generation Pipeline](#report-generation-pipeline)
9. [Notification System](#notification-system)
10. [Scan Profiles](#scan-profiles)
11. [Key Design Decisions and Trade-offs](#key-design-decisions-and-trade-offs)
12. [Future Considerations](#future-considerations)

---

## System Overview and Goals

The Web Application Penetration Testing Platform is an automated security scanning system built with Ruby on Rails. It orchestrates multiple best-in-class open-source security tools against target web applications, aggregates and deduplicates findings across tools, enriches results with CVE intelligence from public databases, applies AI-driven analysis via Claude API, and generates professional reports.

### Primary Goals

- **Automation:** Eliminate manual orchestration of disparate security tools.
- **Intelligence:** Enrich raw scanner output with CVE data and AI-powered triage to separate signal from noise.
- **Consistency:** Produce repeatable, professional reports across scan runs.
- **Extensibility:** Add new scanners or intelligence sources without modifying core orchestration logic.
- **Ethical operation:** Enforce programmatic scope constraints and require explicit authorization for all scanning activity.

### Target Users

- Security engineers conducting authorized penetration tests
- DevSecOps teams running scheduled vulnerability assessments
- Security consultants generating client-facing reports

---

## Architecture

### High-Level System Diagram

```
+-------------------+     +-------------------+     +-------------------+
|  Cloud Scheduler  |---->|  Cloud Run Job    |---->|  ScanOrchestrator |
|  (cron trigger)   |     |  4 vCPU / 16 GB   |     |  (coordinator)    |
+-------------------+     +-------------------+     +--------+----------+
                                                              |
                          +-----------------------------------+-----------------------------------+
                          |                                   |                                   |
               +----------v----------+             +----------v----------+             +----------v----------+
               | Phase 1: Discovery  |             | Phase 2: Active     |             | Phase 3: Targeted   |
               | ffuf + Nikto        |             | OWASP ZAP           |             | Nuclei + sqlmap     |
               | (parallel)          |             | (full DAST)         |             | (parallel)          |
               +----------+----------+             +----------+----------+             +----------+----------+
                          |                                   |                                   |
                          +-----------------------------------+-----------------------------------+
                                                              |
                                                   +----------v----------+
                                                   | FindingNormalizer   |
                                                   | SHA256 fingerprint  |
                                                   | deduplication       |
                                                   +----------+----------+
                                                              |
                                                   +----------v----------+
                                                   | CveIntelligence     |
                                                   | NVD + CISA KEV +    |
                                                   | EPSS + OSV          |
                                                   +----------+----------+
                                                              |
                                                   +----------v----------+
                                                   | AiAnalyzer          |
                                                   | Claude API triage + |
                                                   | executive summary   |
                                                   +----------+----------+
                                                              |
                                                   +----------v----------+
                                                   | ReportGenerator     |
                                                   | JSON + HTML + PDF   |
                                                   +----------+----------+
                                                              |
                                            +-----------------+-----------------+
                                            |                                   |
                                 +----------v----------+             +----------v----------+
                                 | StorageService      |             | NotificationService |
                                 | GCS / local fallback|             | Slack + Email       |
                                 +---------------------+             +---------------------+
```

### Infrastructure (GCP via Pulumi)

```
+------------------+     +---------------------+     +-------------------+
| Artifact Registry|     | GCP Secret Manager  |     | Cloud Storage     |
| (Docker images)  |     | (API keys, creds)   |     | (reports, 90-day) |
+------------------+     +---------------------+     +-------------------+
        |                         |                           |
        +-------------------------+---------------------------+
                                  |
                       +----------v----------+
                       | Cloud Run Job       |
                       | pentest-scanner     |
                       | SA: pentest-scanner |
                       +----------+----------+
                                  |
                       +----------v----------+
                       | Cloud Scheduler     |
                       | default: 0 2 * * *  |
                       +---------------------+

+---------------------+     +---------------------+
| Cloud Function      |     | Cloud Scheduler     |
| vm-scavenger        |<----| every 10 minutes    |
| - SSH liveness check|     +---------------------+
| - 30 min soft limit |
| - 4 hr hard limit   |
| - Slack reporting   |
+---------------------+
```

### VM Lifecycle Management

Scan VMs are ephemeral and self-terminate on completion via an EXIT trap.
A Cloud Function scavenger (`vm-scavenger`) runs every 10 minutes as a safety net:

| VM Age | Action |
|--------|--------|
| < 30 min | Skip (too young) |
| 30 min – 4 hr | SSH check: if scan container running, skip; if idle/unreachable, delete |
| > 4 hr | Force delete regardless of state |

Slack notifications include: VM name, age, zone, deletion reason, and any killed container details.

---

## Phased Scan Execution Model

Scans execute in three sequential phases, where each phase feeds data forward to subsequent phases. This design maximizes coverage: discovery informs active scanning, which informs targeted testing.

### Phase 1: Discovery

**Purpose:** Map the attack surface by discovering endpoints, directories, and server configurations.

**Tools:**
- **ffuf** -- Directory and endpoint brute-forcing using SecLists wordlists. Discovers hidden paths, backup files, and API endpoints.
- **Nikto** -- Server misconfiguration detection. Identifies outdated software, dangerous files, and insecure headers.

**Execution:** Tools run in parallel (thread-per-tool) when the scan profile specifies `parallel: true`.

**Output:** Discovered URLs are collected in `@discovered_urls` and merged into the Target's URL list for subsequent phases.

### Phase 2: Active Scan

**Purpose:** Comprehensive dynamic application security testing (DAST) against all known endpoints.

**Tools:**
- **OWASP ZAP** -- Full or baseline DAST scan depending on profile. Crawls the application, identifies injection points, tests for XSS, CSRF, and other OWASP Top 10 vulnerabilities.

**Execution:** Sequential. ZAP receives the expanded URL list from Phase 1.

### Phase 3: Targeted

**Purpose:** Deep, focused testing for specific vulnerability classes using the intelligence gathered in earlier phases.

**Tools:**
- **Nuclei** -- Template-based scanning against 11,000+ vulnerability signatures. Severity filtering configurable per profile.
- **sqlmap** -- Dedicated SQL injection detection and exploitation testing. Level and risk parameters configurable.

**Execution:** Tools run in parallel when configured.

### Fail-Forward Design

Each tool execution is wrapped in a `rescue StandardError` block within `ScanOrchestrator#run_tool`. If one tool fails (timeout, crash, binary not found), the scan continues with remaining tools. The failure is logged and recorded in `scan.tool_statuses`, but the overall scan proceeds to completion. This ensures partial results are always captured.

---

## Data Model Design

All models use UUID primary keys (36-character string IDs) to avoid sequential integer enumeration. SQLite is the database engine, running in-container.

### Entity Relationship Diagram

```
+-------------------+          +-------------------+          +-------------------+
|     Target        |  1----*  |      Scan         |  1----*  |     Finding       |
+-------------------+          +-------------------+          +-------------------+
| id (UUID, PK)     |          | id (UUID, PK)     |          | id (UUID, PK)     |
| name              |          | target_id (FK)    |          | scan_id (FK)      |
| urls (JSON)       |          | profile           |          | source_tool       |
| auth_type         |          | status            |          | severity          |
| auth_config (JSON)|          | tool_statuses(JSON|          | title             |
| scope_config(JSON)|          | summary (JSON)    |          | url               |
| brand_config(JSON)|          | started_at        |          | parameter         |
| active            |          | completed_at      |          | cwe_id            |
| timestamps        |          | error_message     |          | cve_id            |
+-------------------+          | timestamps        |          | cvss_score        |
                               +-------------------+          | epss_score        |
                                        |                     | kev_known_expl.   |
                                        |                     | evidence (JSON)   |
                                   1----*                     | ai_assessment(JSON|
                               +-------------------+          | fingerprint       |
                               |     Report        |          | duplicate         |
                               +-------------------+          | timestamps        |
                               | id (UUID, PK)     |          +-------------------+
                               | scan_id (FK)      |
                               | format            |
                               | status            |
                               | gcs_path          |
                               | signed_url        |
                               | signed_url_expires |
                               | timestamps        |
                               +-------------------+
```

### Model Details

**Target**
- Represents a scanning engagement. Holds one or more URLs, authentication configuration, scope constraints, and branding preferences for reports.
- `auth_type` enum: `none`, `basic`, `bearer`, `cookie`.
- `scope_config` defines programmatic allowlists for scan boundaries.
- `brand_config` stores client-specific branding for report generation.

**Scan**
- A single execution run against a Target using a specific profile.
- `status` enum: `pending`, `running`, `completed`, `failed`, `cancelled`.
- `tool_statuses` (JSON) tracks per-tool status, timestamps, and errors independently.
- `summary` (JSON) holds aggregated finding counts by severity, tools run, and duration.

**Finding**
- Individual vulnerability detected by a scanner tool.
- `fingerprint` is a SHA256 hash of `title + url + parameter + cwe_id`, enabling cross-tool deduplication.
- `evidence` (JSON) holds tool-specific raw evidence, NVD descriptions, and references.
- `ai_assessment` (JSON) stores Claude API triage results (false positive likelihood, priority, remediation).
- CVE enrichment fields: `cve_id`, `cvss_score`, `epss_score`, `kev_known_exploited`.

**Report**
- Generated output artifact linked to a Scan.
- `format` enum: `json`, `html`, `pdf`.
- `gcs_path` is the object path in Cloud Storage.
- `signed_url` and `signed_url_expires_at` provide time-limited access.

---

## Service Layer Design

The service layer follows the Single Responsibility Principle (SRP), with each class handling one concern. Effective line counts are kept under 75 lines per module.

### ScanOrchestrator

Central coordinator. Loads the scan profile, iterates through phases, delegates to scanner classes, feeds discovered URLs forward between phases, and manages scan lifecycle (status transitions, error handling).

Key behaviors:
- Thread-based parallelism for tools within a phase.
- Discovered URL aggregation across phases via `@discovered_urls`.
- Fail-forward: tool exceptions are caught and logged, not propagated.
- Post-scan: delegates to `FindingNormalizer` for deduplication and `ScanSummaryBuilder` for summary generation.

### ScannerBase

Abstract base class for all scanner implementations. Provides:
- Template Method pattern: subclasses implement `#execute` and `#tool_name`.
- `#run_command` helper for shelling out with configurable timeouts.
- Per-tool status tracking in `scan.tool_statuses`.
- Output directory management under `tmp/scans/{scan_id}/{tool_name}/`.
- Command safety via `Shellwords` for argument escaping.

### Scanner Implementations

| Scanner | Tool | Key Configuration |
|---------|------|-------------------|
| `Scanners::ZapScanner` | OWASP ZAP | mode (baseline/full), ajax_spider |
| `Scanners::NucleiScanner` | Nuclei | severity_filter, custom templates |
| `Scanners::SqlmapScanner` | sqlmap | level (1-5), risk (1-3) |
| `Scanners::FfufScanner` | ffuf | wordlist, threads, extensions |
| `Scanners::NiktoScanner` | Nikto | tuning parameters |
| `Scanners::DawnScanner` | Dawnscanner | Ruby dependency audit |

### ResultParsers

Each scanner has a corresponding parser that normalizes tool-specific output formats into a uniform finding structure:

| Parser | Input Format | Output |
|--------|-------------|--------|
| `ResultParsers::ZapParser` | ZAP JSON/XML report | Normalized findings |
| `ResultParsers::NucleiParser` | Nuclei JSONL | Normalized findings |
| `ResultParsers::SqlmapParser` | sqlmap log output | Normalized findings |
| `ResultParsers::FfufParser` | ffuf JSON | Discovered URLs + findings |
| `ResultParsers::NiktoParser` | Nikto JSON/CSV | Normalized findings |
| `ResultParsers::DawnParser` | Dawn JSON | Normalized findings |

### FindingNormalizer

Post-scan deduplication service. Generates tool-agnostic fingerprints by hashing `title + normalized_url (host+path only) + parameter + cwe_id`. Findings with duplicate fingerprints are flagged as `duplicate: true` and excluded from reports and AI analysis.

### ScanSummaryBuilder

Builds the scan summary JSON: total non-duplicate finding count, severity distribution, tools executed, and scan duration.

---

## AI Assessment Layer

The AI layer uses Claude API (via the `anthropic` gem) to add expert-level analysis to automated scanner output.

### Components

**Ai::ClaudeClient**
- Thin wrapper around the Anthropic SDK. Handles API calls and JSON response extraction from markdown-fenced code blocks.
- Model configurable via `CLAUDE_MODEL` env var (default: `claude-sonnet-4-20250514`).

**Ai::FindingTriager**
- Sends batches of up to 20 findings to Claude for expert triage.
- For each finding, Claude assesses:
  - `false_positive_likelihood` (high/medium/low)
  - `business_impact` (real-world impact assessment)
  - `priority` (immediate/short_term/long_term/accept_risk)
  - `remediation` (specific, actionable fix)
  - `attack_chain` (how the finding combines with others)
- Results stored in `finding.ai_assessment` (JSON).

**Ai::ExecutiveSummarizer**
- Generates narrative executive summary for the full scan, suitable for non-technical stakeholders.

**AiAnalyzer (Facade)**
- Orchestrates triage and summarization. Processes findings in batches, then generates the executive summary.

**Adaptive Scanning (suggest_additional_tests)**
- After Phase 1 discovery, Claude can analyze discovered endpoints to suggest targeted tests: SQL injection candidates, auth bypass targets, API endpoints for IDOR testing, and misconfiguration indicators.

**NucleiTemplateGenerator**
- Generates custom Nuclei YAML templates for specific CVEs using Claude.
- Templates are validated for correct structure before saving to `custom_templates/nuclei/`.
- Enables detection of newly disclosed vulnerabilities before official Nuclei templates are available.

---

## CVE Intelligence Layer

All CVE intelligence sources are free public APIs, avoiding vendor lock-in and licensing costs.

### Data Sources

**NVD API v2 (National Vulnerability Database)**
- Source of truth for CVE details.
- Provides: CVSS scores, vulnerability descriptions, affected product lists (CPE), reference URLs.
- Rate-limited; the platform applies 0.7-second delays between requests.
- Optional `NVD_API_KEY` increases rate limits.

**CISA KEV (Known Exploited Vulnerabilities)**
- Binary check: is this CVE actively exploited in the wild?
- Findings flagged `kev_known_exploited: true` receive elevated priority.
- Critical for distinguishing theoretical risk from active threat.

**EPSS (Exploit Prediction Scoring System)**
- Probability score (0.0-1.0) indicating likelihood of exploitation in the next 30 days.
- Stored as `epss_score` on findings.
- Helps prioritize remediation when multiple vulnerabilities compete for attention.

**OSV (Open Source Vulnerabilities)**
- Queries open-source package vulnerabilities by name and ecosystem.
- Used by DawnScanner integration for Ruby dependency auditing.

### CveIntelligenceService

Facade that coordinates enrichment across all four sources. Processes findings sequentially with rate-limiting delays. Enrichment failures are logged but do not block scan completion (fail-forward).

---

## Report Generation Pipeline

### Generation Flow

```
Scan (completed)
  |
  v
ReportGenerator
  |
  +---> JsonReport  ---> raw JSON dump of all findings + metadata
  |
  +---> HtmlReport  ---> ERB template with severity charts, finding details
  |       |                brand_config applied (logo, colors, company name)
  |       v
  +---> PdfReport   ---> Grover (Puppeteer/Chromium) renders HTML to PDF
          |                executive summary, severity breakdown, details
          v
     save_local (tmp/reports/{scan_id}/)
          |
          v
     StorageService.upload (GCS or local fallback)
          |
          v
     Report record updated with gcs_path + signed_url (7-day expiry)
```

### Report Formats

**JSON Report**
- Machine-readable. Contains full finding data, scan metadata, target configuration, and enrichment data.
- Suitable for ingestion by other security tools, SIEMs, or dashboards.

**HTML Report**
- Professional, branded vulnerability report.
- ERB template at `app/views/reports/`.
- Client-specific branding via `target.brand_config` (logo, colors, company name).
- Severity distribution, finding details with evidence, remediation guidance.

**PDF Report**
- Generated from the HTML report using Grover (Puppeteer with Chromium).
- `GROVER_NO_SANDBOX=true` for container compatibility.
- Includes executive summary narrative from AI analysis.
- Suitable for formal delivery to clients and stakeholders.

### Storage

- **GCS mode:** Reports uploaded to a versioned bucket with 90-day lifecycle policy. Accessed via signed URLs with 7-day expiry.
- **Local fallback:** When GCS is not configured, reports are saved to `storage/reports/` with `file://` URLs. Suitable for development and testing.

---

## Notification System

### Slack Webhooks

- Sends structured Block Kit messages to a configured Slack channel.
- Message includes: target name, scan profile, total findings, and severity breakdown (critical/high/medium/low).
- Configured via `SLACK_WEBHOOK_URL` environment variable.
- Gracefully skipped when not configured.

### Email via authsmtp.com

- SMTP delivery using the `mail` gem.
- HTML-formatted email with scan summary.
- Configured via `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, `NOTIFICATION_EMAIL`.
- Uses authsmtp.com (port 2525) as the relay provider.

### Fault Tolerance

Both notification channels are wrapped in exception handlers. Notification failures are logged but never cause scan failures.

---

## Scan Profiles

Scan profiles are YAML configuration files in `config/scan_profiles/`. The `ScanProfile` value object parses them and exposes phase/tool configuration to the orchestrator.

### Available Profiles

#### Quick (~10 minutes)

```yaml
phases:
  - name: discovery
    tools: []                  # No discovery phase
  - name: active_scan
    tools:
      - tool: zap
        mode: baseline         # ZAP baseline scan only
        timeout: 300
  - name: targeted
    tools:
      - tool: nuclei
        severity_filter: critical,high    # Critical + high only
        timeout: 300
```

**Use case:** Fast sanity check, CI/CD integration, smoke testing after deployments.

#### Standard (~30 minutes)

```yaml
phases:
  - name: discovery
    tools:
      - tool: ffuf
        wordlist: common.txt
        threads: 40
      - tool: nikto
    parallel: true
  - name: active_scan
    tools:
      - tool: zap
        mode: full
        timeout: 900
  - name: targeted
    tools:
      - tool: nuclei
        severity_filter: critical,high,medium
        timeout: 600
```

**Use case:** Regular scheduled scans, standard penetration test engagements.

#### Thorough (~2 hours)

```yaml
phases:
  - name: discovery
    tools:
      - tool: ffuf
        wordlist: directory-list-2.3-medium.txt
        extensions: ".php,.asp,.aspx,.jsp,.html,.js,.json,.xml,.txt,.bak,.old,.conf,.sql,.log"
      - tool: nikto
        tuning: "1234567890abc"      # All test categories
    parallel: true
  - name: active_scan
    tools:
      - tool: zap
        mode: full
        ajax_spider: true            # JavaScript-heavy app crawling
        timeout: 1800
  - name: targeted
    tools:
      - tool: nuclei
        severity_filter: critical,high,medium,low    # All severities
        timeout: 1200
      - tool: sqlmap
        level: 3                     # Deep injection testing
        risk: 2                      # Moderate risk payloads
        timeout: 1200
    parallel: true
```

**Use case:** Comprehensive security assessment, pre-release audits, compliance-driven testing.

### Profile Extensibility

New profiles are added by creating a YAML file in `config/scan_profiles/`. No code changes required. The `ScanProfile` value object automatically discovers available profiles via `Dir.glob`. Tool configurations are passed through to scanner classes via `ToolConfig#config`, allowing arbitrary per-tool settings.

---

## Key Design Decisions and Trade-offs

### SQLite In-Container

**Decision:** Use SQLite as the database, running inside the Cloud Run container.

**Rationale:** Each scan execution is an ephemeral job. The database exists only for the duration of the scan to structure findings and relationships. Persistent storage is handled by GCS (reports) and notifications. This eliminates the operational overhead of managing a Cloud SQL instance, reduces cost, and simplifies the deployment model.

**Trade-off:** No cross-scan querying, historical trend analysis, or dashboard views from the database. These capabilities would require Cloud SQL migration (see Future Considerations).

### Docker Multi-Stage Build

**Decision:** Two-stage Dockerfile -- a tools layer (Ubuntu 22.04) and an app layer (Ruby 3.2 slim).

**Rationale:** The scanner tools span five different runtime ecosystems: Java (ZAP), Go (Nuclei, ffuf), Python (sqlmap, ZAP scripts), Perl (Nikto), and Ruby (Rails app, Dawnscanner). The multi-stage build isolates tool installation from the application layer, producing a single unified image that can be deployed as a Cloud Run job.

**Trade-off:** Large image size due to the tool chain. Mitigated by selective SecLists inclusion (only common.txt and directory-list-2.3-medium.txt) and `--no-install-recommends`.

### Phased Execution with URL Feed-Forward

**Decision:** Three sequential phases where discovery results feed into subsequent phases.

**Rationale:** Running all tools independently misses the intelligence chain. Directory brute-forcing (ffuf) discovers endpoints that ZAP would not crawl to. ZAP's crawling finds forms and parameters that sqlmap should test. The phased model ensures each tool receives the most complete target surface.

**Trade-off:** Sequential phases increase total scan duration. Mitigated by intra-phase parallelism and configurable timeouts.

### SRP: 75 Effective Lines Maximum

**Decision:** All modules limited to 75 effective lines (excluding blanks, comments, imports).

**Rationale:** Enforces small, focused classes that are easy to test, review, and maintain. Each service does one thing well. The scanner ecosystem is naturally decomposed: ScannerBase (template), per-tool scanners (execution), per-tool parsers (normalization).

**Trade-off:** More files to navigate. Mitigated by clear directory structure and naming conventions.

### Fail-Forward Scanning

**Decision:** Individual tool failures do not abort the scan.

**Rationale:** Security scanning tools are inherently unreliable -- they time out, crash on malformed responses, or fail on edge cases. A scan with 4 out of 5 tools succeeding is far more valuable than no scan at all. Tool failures are recorded in `scan.tool_statuses` for visibility.

**Trade-off:** A scan may report "completed" with incomplete coverage. Mitigated by tool status tracking and notification messages that include which tools ran.

### SHA256 Fingerprint Deduplication

**Decision:** Cross-tool deduplication via SHA256 hash of normalized finding attributes (title, host+path, parameter, CWE).

**Rationale:** Multiple tools often detect the same vulnerability (e.g., ZAP and Nuclei both find the same XSS). URL normalization (stripping scheme, query, fragment) ensures findings from different tools that target the same endpoint are recognized as duplicates.

**Trade-off:** Aggressive normalization may occasionally merge distinct findings. The `duplicate` flag is soft -- original findings are preserved in the database.

---

## Future Considerations

### Authenticated Scanning
- Extend `auth_config` to support OAuth2 flows, SAML SSO, and custom authentication scripts.
- Session management for tools that require authenticated crawling (ZAP context files, Nuclei header injection).

### Cloud SQL Migration
- Replace SQLite with Cloud SQL (PostgreSQL) for persistent storage across scan runs.
- Enables historical trend analysis, regression detection, and dashboard views.
- Required before building a web UI.

### Web UI
- Rails-based dashboard for scan management, finding review, and report access.
- Real-time scan progress via ActionCable (WebSocket).
- Finding workflow: triage, assign, track remediation status.

### Additional Scanners
- **Semgrep** for static analysis of source code (if access is available).
- **TLS/SSL testing** via testssl.sh or sslyze.
- **API fuzzing** via RESTler or custom OpenAPI-driven testing.

### Scheduled Differential Scanning
- Compare findings across scan runs to identify new, resolved, and recurring vulnerabilities.
- Alert only on deltas to reduce notification fatigue.

### Multi-Target Orchestration
- Parallel scan execution across multiple targets.
- Target groups with shared authentication and reporting configurations.
