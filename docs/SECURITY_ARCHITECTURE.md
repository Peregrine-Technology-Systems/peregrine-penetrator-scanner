---
title: Security Architecture
---

# Security Architecture Review

**Version:** 2.0
**Last Updated:** 2026-03-28
**Scope:** Security posture of the penetration testing platform itself (not the targets being scanned)

---

## Threat Model

This threat model addresses risks to the platform itself. The platform handles sensitive data (vulnerability findings, target credentials, API keys) and has the capability to execute offensive security tools against network targets.

### Assets

| Asset | Sensitivity | Location |
|-------|------------|----------|
| Scan findings (vulnerability details) | High | SQLite (ephemeral), GCS (persistent) |
| Target authentication credentials | Critical | `auth_config` field, Secret Manager |
| API keys (NVD) | High | Environment variables, Secret Manager |
| Slack webhook URL | Medium | Environment variable, Secret Manager |
| Docker image (contains tool binaries) | Medium | Artifact Registry |
| Source code | Medium | GitHub repository (public) |
| Control plane tokens (SCAN_CALLBACK_SECRET) | High | Secret Manager, VM metadata |
| GCS control signals (cancel, dead letter) | Medium | GCS bucket |

### Threat Actors

| Actor | Motivation | Capability |
|-------|-----------|------------|
| External attacker | Access vulnerability data to exploit targets | Network access, credential theft |
| Malicious insider | Misuse platform to scan unauthorized targets | Platform access, credential access |
| Supply chain attacker | Compromise scanner tools or dependencies | Dependency poisoning, image tampering |
| Cloud infrastructure compromise | Lateral movement from other GCP workloads | GCP IAM, service account impersonation |

### Primary Threat Scenarios

1. **Unauthorized scan execution** -- An attacker triggers scans against targets they lack authorization to test.
2. **Credential exfiltration** -- Target auth credentials or API keys are extracted from the environment or storage.
3. **Scanner tool compromise** -- A malicious update to a bundled tool (ZAP, Nuclei, sqlmap) introduces backdoor behavior.
4. **Control plane abuse** -- Forged heartbeats or cancel signals disrupt scan operations.
5. **Dead letter data exposure** -- callback_pending.json in GCS contains scan metadata accessible to anyone with bucket access.

---

## Secrets Management

### Architecture

**Development/Local:**
- Secrets stored in `.env` files (`.env`, `.env.development`, `.env.test`).
- `.env*` patterns are in `.gitignore` -- no secrets reach version control.

**Production (GCP):**
- All secrets stored in GCP Secret Manager with `pentest-` prefix.
- Scan VMs fetch secrets at boot via `gcloud secrets versions access`.
- Secrets passed as Docker `-e` environment variables (never baked into images).

### Managed Secrets

| Secret | Purpose | Rotation |
|--------|---------|----------|
| `pentest-nvd-api-key` | NVD API rate limit increase | Manual, NIST |
| `pentest-scan-callback-secret` | Heartbeat + callback auth | Manual |
| `pentest-slack-webhook-url` | Scan completion notifications | Manual |

### Control Plane Secrets

| Secret | Purpose | Scope |
|--------|---------|-------|
| `SCAN_CALLBACK_SECRET` | Bearer token for heartbeat + callback auth | Per-environment |
| `REPORTER_BASE_URL` | Reporter endpoint for heartbeats | Per-environment |

Both are passed via VM metadata and injected as environment variables. The callback secret authenticates all scanner-to-reporter communication.

---

## Container Security

### Hybrid Docker Model

| Environment | Image | Security Properties |
|-------------|-------|-------------------|
| Development | Clone at boot (interactive VM) | Mutable, developer access |
| Staging | `scanner:staging` (baked) | Immutable freeze point, tested |
| Production | `scanner:production` (re-tagged staging) | Identical bytes to staging |

### Image Layers

| Layer | Base | Contents |
|-------|------|----------|
| `scanner-base` | `ubuntu:22.04` + `ruby:3.2.2-slim` | Security tools, Python deps |
| `scanner` | `FROM scanner-base` | Gems + app code |

### VM Isolation

Scan VMs are ephemeral GCE instances (not Cloud Run):
- Each scan runs on a fresh spot VM that self-terminates
- EXIT trap ensures VM deletion on any exit (success, failure, crash)
- Trap self-check aborts VM if trap setup fails
- Scavenger Cloud Function deletes orphans (>4hr force delete)
- No persistent state between scans

---

## Network Security

### Ephemeral VM Network Model

```
Ephemeral GCE VM (scan duration only)
  |
  |  Egress only
  |
  +---> Target URLs (scan tools)
  +---> NVD, EPSS, KEV, OSV APIs (CVE enrichment)
  +---> Reporter (heartbeats + callback)
  +---> GCS (results, control signals)
  +---> BigQuery (findings, costs)
  +---> Slack (notifications)
```

All outbound connections use HTTPS/TLS. VMs have no ingress listeners.

---

## Control Plane Security

### Heartbeat + Callback Authentication

All scanner-to-reporter communication uses Bearer token authentication:

```
Authorization: Bearer {SCAN_CALLBACK_SECRET}
```

The secret is stored in GCP Secret Manager and injected at VM boot.

### Cancel Signal Security

Cancel signals are written to GCS (`control/{scan_uuid}/control.json`) by the reporter. The scanner reads but never writes cancel signals. GCS IAM controls who can write to the control path.

### Cloud Function Dispatch Security

The `trigger_scan` Cloud Function accepts request parameters from the reporter but enforces infrastructure boundaries:

| Concern | How it's handled |
|---------|-----------------|
| `SCAN_CALLBACK_SECRET` | Never in request body or VM metadata — fetched from Secret Manager at boot |
| Infrastructure config | Registry, service account, GCS bucket always from function env (not request) |
| Backward compatibility | Empty request body triggers default scan (Cloud Scheduler) |
| VM naming | Includes `scan_uuid[:8]` for traceability |

### Risks

| Risk | Mitigation |
|------|-----------|
| Forged heartbeats | Bearer token auth, reporter validates job_id exists |
| Forged cancel signals | GCS IAM restricts write access to reporter SA |
| Dead letter data exposure | GCS bucket IAM, no public access |
| Replay attacks on callback | Callback URL includes job_id, reporter validates once-only |
| Unauthorized scan dispatch | Cloud Function requires IAM authentication (Cloud Functions Invoker role) |

---

## Data Handling

### Sensitivity Classification

| Data Type | Classification | Retention | Storage |
|-----------|---------------|-----------|---------|
| Raw scanner output | High | Ephemeral (scan duration) | VM filesystem |
| Findings database | High | Ephemeral (scan duration) | SQLite in container |
| JSON scan results | High | 18 months | GCS bucket |
| Scan logs | Medium | Ephemeral (VM lifetime) | stdout (Cloud Logging) |
| Control signals | Low | Ephemeral | GCS bucket |
| BigQuery findings | High | 18 months | BigQuery |

### Data Lifecycle

1. **Creation:** Scan tools write raw output to `tmp/scans/{scan_id}/{tool}/`.
2. **Processing:** Result parsers normalize findings into SQLite.
3. **Enrichment:** CVE intelligence added from NVD, KEV, EPSS, OSV.
4. **Export:** v1.0 JSON envelope uploaded to GCS.
5. **Logging:** Findings + metadata logged to BigQuery.
6. **Callback:** Summary POSTed to reporter (reporter generates reports).
7. **Destruction:** VM self-terminates; SQLite, raw output destroyed.
8. **Expiry:** 18-month retention policy on GCS and BigQuery.

---

## Scope Enforcement

### Programmatic Allowlists

- `Target.scope_config` (JSON) defines the allowlist for scan boundaries.
- `Target.urls` explicitly lists authorized URLs.
- Scanner tools receive only the URLs from the Target record.
- `ScanOrchestrator#feed_discovered_urls` merges discovered URLs into the target's URL list.

### Risks

- **Scope creep via discovery:** ffuf may discover URLs on different domains.
- **Crawler following redirects:** ZAP's spider may follow redirects to out-of-scope domains.

---

## CI/CD Security

### Woodpecker CI (Self-Hosted)

**Secrets management:**
- Woodpecker repo-level secrets (`gh_token`, `slack_webhook_url`, `docker_registry`).
- Secrets injected via `from_secret:` directive (never in YAML).
- GCP secrets fetched at runtime via `gcloud secrets versions access`.

**Pipeline security:**
- Pipelines defined in `.woodpecker/*.yaml` (version controlled).
- `backend: local` -- runs on host (pre-installed tools via Packer image).
- No arbitrary code execution from PRs (branch protection enforced).
- Manual approval required for staging-to-main promotion.

### Container Image Pipeline

```
Source Code (GitHub) → Woodpecker CI → Docker Build → Artifact Registry
                                                        ↓
                                            scanner:staging (baked)
                                                        ↓
                                            scanner:production (re-tagged)
```

Immutable image tags per environment. Staging image bytes = production image bytes.

---

## Supply Chain Security

### Ruby Dependencies

All gem versions pinned via `Gemfile.lock`. `bundle config deployment true` in Dockerfile ensures exact versions.

| Gem | Purpose | Risk |
|-----|---------|------|
| `sequel ~> 5.78` | ORM | Low (well-maintained) |
| `google-cloud-storage ~> 1.44` | GCS access | Low (Google-maintained) |
| `google-cloud-bigquery ~> 1.49` | BigQuery | Low (Google-maintained) |
| `faraday ~> 2.7` | HTTP client | Low (widely used) |
| `sqlite3 ~> 1.4` | Database driver | Low |

### Security Tool Binaries

| Tool | Source | Verification |
|------|--------|-------------|
| OWASP ZAP | Official Docker image | Image digest |
| Nuclei | GitHub Releases | SHA256 not verified |
| sqlmap | Git clone | Commit SHA |
| ffuf | GitHub Releases | SHA256 not verified |
| Nikto | Git clone | Commit SHA |

---

## Recommendations for Hardening

### Priority 1: Critical

1. **Verify tool binary checksums.** Add SHA256 verification for all downloaded binaries.
2. **Scope enforcement for discovered URLs.** Validate against `scope_config` before adding.
3. **Prevent credential logging.** Filter `auth_config` and API keys from logs.

### Priority 2: High

4. **Run container as non-root.** Create dedicated user in Dockerfile.
5. **Pin Docker base images by digest.** Use `ruby@sha256:...` references.
6. **Implement image signing.** Use cosign for Artifact Registry images.
7. **Scope Secret Manager access.** Resource-level IAM per secret.

### Priority 3: Medium

8. **Add authorization document tracking.** Link targets to signed scope agreements.
9. **VPC and egress controls.** Deploy VMs within VPC with firewall rules.
10. **Container vulnerability scanning.** Trivy or Artifact Registry scanning in CI.
11. **Control plane rate limiting.** Limit heartbeat frequency per scan to prevent abuse.
