# System Architecture

| | |
|---|---|
| **Document** | Peregrine Penetrator Scanner — System Architecture |
| **Classification** | CONFIDENTIAL |
| **Version** | 1.0 |
| **Date** | 2026-03-22 |
| **Author** | Peregrine Technology Systems |

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-22 | Peregrine Technology Systems | Initial architecture document |

---

## Overview

The Peregrine Penetration Testing Platform is a three-service architecture that automates web application security assessments. Each service has a single, clearly defined responsibility.

```mermaid
graph TB
    subgraph Backend ["Backend (Orchestrator)"]
        API[API Server]
        ClientMgmt[Client Management]
        Auth[Authentication]
    end

    subgraph Scanner ["Scanner (Ephemeral VM)"]
        Scanners[Security Scanners]
        CVE[CVE Enrichment]
        Exporter[JSON Exporter]
    end

    subgraph Reporter ["Reporter (Cloud Run)"]
        AI[AI Analysis]
        ReportGen[Report Generation]
    end

    subgraph Storage ["Data Stores"]
        GCS[Google Cloud Storage]
        BQ[BigQuery]
    end

    API -->|Provisions VM| Scanner
    Scanners --> CVE
    CVE --> Exporter
    Exporter -->|Versioned JSON| GCS
    Exporter -->|Load from JSON| BQ
    Exporter -->|Callback| API
    API -->|Triggers| Reporter
    Reporter -->|Reads JSON| GCS
    AI --> ReportGen
    ReportGen -->|Reports| GCS
    ReportGen -->|Callback| API
```

## Services

### Scanner (`peregrine-penetrator-scanner`)

**Role:** Execute security scans against a single target URL, enrich findings with CVE intelligence, and output a versioned JSON artifact.

**Deployment:** Ephemeral DigitalOcean VMs, one per URL. Destroyed after scan completes.

**Technology:** Ruby + Sequel ORM + SQLite (ephemeral state)

**Responsibilities:**
- Run security scanning tools (OWASP ZAP, Nuclei, sqlmap, ffuf, Nikto)
- Parse and normalize tool output
- Deduplicate findings via SHA256 fingerprinting
- Enrich with CVE intelligence (NVD, CISA KEV, EPSS)
- Export versioned JSON artifact to GCS
- Load findings into BigQuery from JSON
- Callback to backend with GCS path

**Does NOT:**
- Generate reports (moved to Reporter)
- Run AI analysis (moved to Reporter)
- Serve HTTP (CLI tool, not web server)
- Handle multiple URLs (one VM per URL)

### Reporter (`peregrine-penetrator-reporter`)

**Role:** Perform AI-driven security analysis and generate professional penetration test reports.

**Deployment:** Cloud Run (scales to zero, HTTP-triggered)

**Technology:** Ruby + Sinatra

**Responsibilities:**
- Read scan results JSON from GCS
- Run AI analysis (multi-provider: Claude, Gemini, Grok)
- Triage findings with AI assessment
- Generate executive summary
- Produce reports: JSON, Markdown, HTML, PDF
- Upload reports to GCS
- Callback to backend with report paths

### Backend (`peregrine-penetrator-backend`)

**Role:** API server and orchestrator. Manages clients, authentication, and dispatches scan/report jobs.

**Deployment:** Persistent server (Rails API)

**Technology:** Ruby on Rails

**Responsibilities:**
- Client and user management
- Authentication (JWT, OAuth2)
- Provision scanner VMs (DigitalOcean)
- Receive scan callbacks, trigger reporter
- Receive report callbacks, notify clients
- Webhook event delivery
- Compliance document generation

## Data Flow

```mermaid
sequenceDiagram
    participant Client
    participant Backend
    participant Scanner as Scanner VM
    participant GCS
    participant BQ as BigQuery
    participant Reporter

    Client->>Backend: Request scan
    Backend->>Scanner: Provision VM (1 URL)
    Scanner->>Scanner: Run scanners (ZAP, Nuclei, sqlmap, ffuf, Nikto)
    Scanner->>Scanner: Normalize + deduplicate findings
    Scanner->>Scanner: CVE enrichment (NVD, KEV, EPSS)
    Scanner->>GCS: Write versioned JSON (v1.0)
    Scanner->>BQ: Load findings from JSON
    Scanner->>Backend: Callback (gcs_scan_results_path)
    Scanner->>Scanner: VM destroyed

    Backend->>Reporter: POST /generate (GCS path + brand_config)
    Reporter->>GCS: Read scan results JSON
    Reporter->>Reporter: AI analysis (triage + executive summary)
    Reporter->>Reporter: Generate reports (JSON, MD, HTML, PDF)
    Reporter->>GCS: Upload reports
    Reporter->>Backend: Callback (report paths)
    Backend->>Client: Notification (reports ready)
```

## JSON Contract

The versioned JSON artifact is the contract between Scanner and Reporter.

```mermaid
graph LR
    Scanner -->|schema v1.0| GCS
    GCS -->|schema v1.0| BQ
    GCS -->|schema v1.0| Reporter

    style GCS fill:#faf5e6,stroke:#c5a55a
```

**Schema versioning rules:**
- Every JSON artifact carries a `schema_version` field
- Every BQ row stamped with the same version
- Field additions/removals/renames require a version bump
- Version changes tracked in GitHub issues and release notes

## Security Boundaries

```mermaid
graph TB
    subgraph PublicInternet ["Public Internet"]
        Target[Target Application]
    end

    subgraph ScannerVM ["Scanner VM (Ephemeral)"]
        ScanEngine[Scan Engine]
    end

    subgraph GCP ["Google Cloud Platform"]
        GCS[Cloud Storage]
        BQ[BigQuery]
        CloudRun[Cloud Run]
        CloudLog[Cloud Logging]
    end

    subgraph BackendInfra ["Backend Infrastructure"]
        BackendAPI[API Server]
    end

    ScanEngine -->|Scans| Target
    ScanEngine -->|Writes| GCS
    ScanEngine -->|Loads| BQ
    ScanEngine -->|Logs| CloudLog
    CloudRun -->|Reads| GCS
    CloudRun -->|Writes| GCS
    CloudRun -->|Logs| CloudLog
    BackendAPI -->|Triggers| CloudRun
```

**Key security properties:**
- Scanner VMs are ephemeral — destroyed after each scan, no persistent state
- Scanner has no inbound ports — it initiates all connections
- Reporter runs on Cloud Run with no persistent state
- All data in transit is encrypted (TLS)
- All data at rest is encrypted (GCS, BQ default encryption)
- Audit logs captured via Cloud Logging, sunk to BQ for long-term retention
- 18-month data retention with automated purge
