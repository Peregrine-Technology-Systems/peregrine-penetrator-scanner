# Architecture

## System Context

The Peregrine Penetrator Scanner is one component of a three-service security scanning platform. Each service has a focused responsibility:

```mermaid
graph LR
    subgraph Platform
        Reporter["Reporter<br/>(Sinatra + Cloud Run)"]
        Scanner["Scanner<br/>(Ruby CLI + GCP VMs)"]
        Backend["Backend<br/>(API + Scheduling)"]
    end

    Reporter -->|POST trigger| Scanner
    Scanner -->|Heartbeats| Reporter
    Scanner -->|Callback + JSON| Reporter
    Scanner -->|JSON to GCS| GCS[(GCS)]
    Scanner -->|Findings + Costs| BQ[(BigQuery)]
    Reporter -->|Fetch JSON| GCS
    Reporter -->|Reports to GCS| GCS
    Backend -->|Schedule scans| Reporter
    Reporter -->|Email + Slack| Users((Users))
```

| Service | Repo | Responsibility |
|---------|------|---------------|
| **Scanner** | `peregrine-penetrator-scanner` | Run security tools, normalize findings, export JSON |
| **Reporter** | `peregrine-penetrator-reporter` | AI analysis, report generation, ticketing, notifications |
| **Backend** | `peregrine-penetrator-backend` | Orchestration API, scheduling, billing |

## Scanner Architecture

### Scan Execution Flow

```mermaid
flowchart TD
    A[bin/scan CLI] --> B{Profile Type?}
    B -->|smoke-test| C[SmokeTestRunner<br/>Canned findings &lt;30s]
    B -->|smoke| D[SmokeChecker<br/>Validate tools/GCS/secrets]
    B -->|quick/standard/thorough| E[ScanOrchestrator]

    E --> F[Phase 1: Discovery<br/>ffuf + Nikto]
    F --> G[Phase 2: Active Scan<br/>OWASP ZAP]
    G --> H[Phase 3: Targeted<br/>Nuclei + sqlmap]
    H --> I[FindingNormalizer<br/>SHA256 dedup]
    I --> J[CveIntelligenceService<br/>NVD + CISA KEV + EPSS + OSV]
    J --> K[ScanResultsExporter<br/>v1.0 JSON to GCS]
    K --> L[BigQueryLogger<br/>Findings + metadata + costs]
    L --> M[ScanCallbackService<br/>POST to reporter]
    M --> N[SlackNotifier<br/>Webhook]

    C --> K
    D --> O[Summary with pass/fail]
```

### Control Plane Protocol

The scanner communicates with the reporter via a heartbeat/cancel protocol:

```mermaid
sequenceDiagram
    participant R as Reporter
    participant S as Scanner VM
    participant G as GCS

    R->>S: POST /trigger (callback_url, job_id, profile)
    S->>S: Boot, mark_running
    S->>G: Write scan_started.json
    S->>R: Heartbeat (ack, progress=0%)

    loop Every 30 seconds
        S->>R: Heartbeat (status, progress, tool, findings)
        S->>G: Check control.json for cancel
    end

    alt Scan completes
        S->>G: Write scan_results.json
        S->>G: Write to BigQuery
        S->>R: POST callback (scan_uuid, gcs_path, status=completed)
    else Cancel signal detected
        S->>S: Stop current tool
        S->>G: Write partial results
        S->>R: POST callback (status=cancelled)
    else Callback fails after 3 retries
        S->>G: Write callback_pending.json (dead letter)
    else Hard timeout (SCAN_TIMEOUT)
        S->>S: Mark failed
        S->>R: POST callback (status=failed)
    end

    S->>S: Self-terminate VM
```

### VM Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Booting: Cloud Function creates VM
    Booting --> TrapCheck: Set EXIT trap
    TrapCheck --> Running: Trap verified
    TrapCheck --> Terminated: Trap missing, force delete

    Running --> Scanning: Pull image, start scan
    Scanning --> Completed: Scan finishes
    Scanning --> Failed: Tool error or timeout
    Scanning --> Cancelled: Control plane cancel

    Completed --> Uploading: Results to GCS + BigQuery
    Failed --> Uploading: Partial results
    Cancelled --> Uploading: Partial results

    Uploading --> Callback: POST to reporter
    Callback --> Terminated: EXIT trap fires
    Terminated --> [*]: VM deleted
```

Scavenger safety net deletes orphans: 30min-4hr via SSH liveness check, >4hr force delete.

## Data Model

```mermaid
erDiagram
    TARGET ||--o{ SCAN : has
    SCAN ||--o{ FINDING : has

    TARGET {
        uuid id PK
        string name
        json urls
        string auth_type
        json scope_config
        json brand_config
        json ticket_config
    }

    SCAN {
        uuid id PK
        uuid target_id FK
        string profile
        string status
        json tool_statuses
        json summary
        datetime started_at
        datetime completed_at
    }

    FINDING {
        uuid id PK
        uuid scan_id FK
        string source_tool
        string severity
        string title
        string url
        string cwe_id
        string cve_id
        string fingerprint
        json evidence
        json ai_assessment
        boolean duplicate
    }
```

All models use UUID primary keys. JSON columns use Sequel's serialization plugin.

## Security Tools

| Tool | Phase | Purpose | Default Timeout |
|------|-------|---------|----------------|
| **ffuf** | Discovery | Directory/endpoint enumeration | 300s |
| **Nikto** | Discovery | Server misconfiguration detection | 300s |
| **OWASP ZAP** | Active | Full DAST scan (baseline or full) | 600s |
| **Nuclei** | Targeted | Template-based CVE scanning (11K+ templates) | 300s |
| **sqlmap** | Targeted | SQL injection detection | 300s |
| **Dawnscanner** | Targeted | Ruby dependency audit | 300s |

### Finding Normalization

Each tool produces findings in its own format. Result parsers (`app/services/result_parsers/`) normalize them into a common schema. The `FindingNormalizer` then deduplicates across tools using SHA256 fingerprints:

```
fingerprint = SHA256("source_tool:title:url:parameter:cwe_id")
```

Findings with identical fingerprints within the same scan are marked as `duplicate: true`.

## CVE Intelligence Enrichment

Findings with CVE IDs are enriched from four sources:

```mermaid
flowchart LR
    F[Finding with CVE ID] --> NVD[NVD API v2<br/>CVSS score]
    F --> KEV[CISA KEV<br/>Known exploited?]
    F --> EPSS[EPSS API<br/>Exploit probability]
    F --> OSV[OSV API<br/>Package advisories]

    NVD --> E[Enriched Finding]
    KEV --> E
    EPSS --> E
    OSV --> E
```

## JSON Export Schema (v1.0)

The scanner exports a versioned JSON envelope to GCS at `scan-results/{target_id}/{scan_id}/scan_results.json`:

```json
{
  "schema_version": "1.0",
  "metadata": {
    "scan_id": "uuid",
    "target_name": "...",
    "target_urls": ["..."],
    "profile": "standard",
    "started_at": "ISO8601",
    "completed_at": "ISO8601",
    "duration_seconds": 1800,
    "tool_statuses": {},
    "generated_at": "ISO8601"
  },
  "summary": {
    "total_findings": 42,
    "by_severity": {"critical": 2, "high": 8, "medium": 15, "low": 12, "info": 5},
    "tools_run": ["zap", "nuclei", "ffuf", "nikto"],
    "duration_seconds": 1800
  },
  "findings": [...]
}
```

See [docs/schema_versioning.md](schema_versioning.md) for the full contract specification.

## Scan Profiles

| Profile | Duration | Discovery | Active | Targeted |
|---------|----------|-----------|--------|----------|
| `quick` | ~10 min | -- | ZAP baseline | Nuclei critical/high |
| `standard` | ~30 min | ffuf + Nikto | ZAP full | Nuclei + sqlmap |
| `thorough` | ~2 hr | ffuf + Nikto | ZAP full (deep) | Nuclei + sqlmap + Dawn |
| `smoke` | <30s | -- | -- | -- (infra validation only) |
| `smoke-test` | <30s | -- | -- | -- (canned findings for deploy verification) |

## Reliability Guarantees

| Mechanism | What it prevents |
|-----------|-----------------|
| **SCAN_TIMEOUT** (default 3600s) | Hung scans running indefinitely |
| **Per-tool timeout** (default 600s) | Individual tool hangs |
| **ControlPlaneLoop tick timeout** (10s) | Hung heartbeat/cancel checks |
| **Heartbeat every 30s** | Reporter detects dead scanners (90s stale threshold) |
| **last_tool_started_at** in heartbeat | Reporter detects hung tools (5min stale threshold) |
| **scan_started.json marker** | Reporter detects started-but-never-completed scans |
| **callback_pending.json dead letter** | Reporter recovers when callback fails |
| **VM self-terminate trap** | No orphan VMs (EXIT trap + scavenger safety net) |
| **VM trap self-check** | VM aborts if trap setup fails |
| **Cancel via GCS control.json** | Reporter can stop stale/runaway scans |
| **Process liveness check** | ScannerBase detects dead tool processes |

## Docker Architecture

### Hybrid Model

- **Development**: Clone repo at VM boot, `bundle install`, run from source (fast iteration)
- **Staging**: Build baked `scanner:staging` image (immutable freeze point)
- **Production**: Re-tag `scanner:staging` as `scanner:production` (zero rebuild, identical bytes)

### Image Layers

| Layer | Contents | Rebuild Frequency |
|-------|----------|------------------|
| **scanner-base** | Ubuntu + ZAP + Nuclei + sqlmap + ffuf + Nikto + Python deps | Monthly |
| **scanner** (app) | Ruby 3.2.2 + bundle install + app code | Every staging build |

## CI/CD Pipeline

```mermaid
flowchart LR
    subgraph Feature
        CI1[ci.yaml<br/>RSpec + RuboCop]
    end

    subgraph Development
        CI2[ci.yaml]
        P1[promote.yaml]
    end

    subgraph Staging
        CI3[ci.yaml]
        B1[build.yaml]
        D1[deploy.yaml]
        SM1[smoke-test.yaml]
        P2[promote.yaml]
    end

    subgraph Main
        VB[version-bump.yaml]
        REL[release.yaml]
        SB[sync-back.yaml]
    end

    CI1 -->|merge| CI2
    CI2 --> P1
    P1 -->|auto| CI3
    CI3 --> B1
    B1 --> D1
    D1 --> SM1
    SM1 --> P2
    P2 -->|manual| VB
    VB --> REL
    REL --> SB
```

| Pipeline | Trigger | Purpose |
|----------|---------|---------|
| `ci.yaml` | Push (not main) | RSpec + RuboCop + check-release-notes |
| `build-base.yaml` | Dockerfile.base changes | Build scanner-base image |
| `build.yaml` | Push to staging | Build baked scanner:staging image |
| `deploy.yaml` | Push to staging/main | Tag image, trigger scan VM |
| `promote.yaml` | Push to dev/staging | Auto-promote to next branch |
| `smoke-test.yaml` | Push to staging | Verify scan outputs in GCS |
| `version-bump.yaml` | Push to main | Bump VERSION, update RELEASE_NOTES, tag |
| `sync-back.yaml` | Tag v* | Sync RELEASE_NOTES to dev/staging |

## Directory Structure

```
peregrine-penetrator-scanner/
  app/
    models/               Value objects (ScanProfile)
    services/             Core business logic
      scanners/           Tool-specific scanner classes
      result_parsers/     Normalize tool output formats
      cve_clients/        NVD, CISA KEV, EPSS, OSV
      notifiers/          Slack alerts
  bin/scan                CLI entry point
  config/scan_profiles/   YAML scan configs
  cloud/lib/              VM startup scripts
  db/sequel_migrations/   Sequel migrations
  docker/                 Dockerfile, docker-compose
  docs/                   Architecture and reference docs
  infra/                  Pulumi IaC for GCP
  lib/
    models/               Sequel models (Target, Scan, Finding)
    penetrator.rb         Boot module
    tasks/                Rake tasks
  scripts/woodpecker/     CI pipeline scripts
  spec/                   RSpec test suite
```
