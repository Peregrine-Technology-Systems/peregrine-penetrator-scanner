# Security Architecture Review

**Version:** 1.0
**Last Updated:** 2026-03-18
**Scope:** Security posture of the penetration testing platform itself (not the targets being scanned)

---

## Table of Contents

1. [Threat Model](#threat-model)
2. [Secrets Management](#secrets-management)
3. [Container Security](#container-security)
4. [Network Security](#network-security)
5. [Data Handling](#data-handling)
6. [Report Security](#report-security)
7. [Authentication for Scanning Targets](#authentication-for-scanning-targets)
8. [Scope Enforcement](#scope-enforcement)
9. [Authorization Context](#authorization-context)
10. [CI/CD Security](#cicd-security)
11. [Supply Chain Security](#supply-chain-security)
12. [Recommendations for Hardening](#recommendations-for-hardening)

---

## Threat Model

This threat model addresses risks to the platform itself. The platform handles sensitive data (vulnerability findings, target credentials, API keys) and has the capability to execute offensive security tools against network targets.

### Assets

| Asset | Sensitivity | Location |
|-------|------------|----------|
| Scan findings (vulnerability details) | High | SQLite (ephemeral), GCS (persistent), reports |
| Target authentication credentials | Critical | `auth_config` field, Secret Manager |
| API keys (Anthropic, NVD, SMTP) | High | Environment variables, Secret Manager |
| Scan reports (JSON, HTML, PDF) | High | GCS bucket, signed URLs |
| Slack webhook URL | Medium | Environment variable, Secret Manager |
| Docker image (contains tool binaries) | Medium | Artifact Registry |
| Source code | Medium | GitHub repository |

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
3. **Report data exposure** -- Vulnerability reports are accessed by unauthorized parties via leaked signed URLs or bucket misconfiguration.
4. **Scanner tool compromise** -- A malicious update to a bundled tool (ZAP, Nuclei, sqlmap) introduces backdoor behavior.
5. **AI prompt injection** -- Scan results contain crafted content that manipulates Claude API responses during triage.

---

## Secrets Management

### Architecture

The platform uses a two-tier secrets model:

**Development/Local:**
- Secrets stored in `.env` files (`.env`, `.env.development`, `.env.test`).
- `.env*` patterns are in `.gitignore` -- no secrets reach version control.
- `.env.example` serves as a template documenting required variables without containing actual values.

**Production (GCP):**
- All secrets stored in GCP Secret Manager with `pentest-` prefix naming convention.
- Cloud Run Job receives secrets via `value_source.secret_key_ref` -- secrets are injected as environment variables at runtime, never baked into the container image.
- Service account `pentest-scanner` is granted `roles/secretmanager.secretAccessor`.

### Managed Secrets

| Secret | Purpose | Rotation |
|--------|---------|----------|
| `pentest-anthropic-api-key` | Claude API access | Manual, API provider |
| `pentest-nvd-api-key` | NVD API rate limit increase | Manual, NIST |
| `pentest-slack-webhook-url` | Scan completion notifications | Manual, Slack admin |
| `pentest-smtp-username` | Email notification relay | Manual, authsmtp.com |
| `pentest-smtp-password` | Email notification relay | Manual, authsmtp.com |
| `pentest-notification-email` | Recipient address | Manual |

### No Secrets in Source Code

**Enforcement mechanisms:**
- `.gitignore` excludes `.env*`, `/storage/*`, `/tmp/*`, and `/log/*`.
- All credential access uses `ENV.fetch` or `ENV['KEY']` -- never hardcoded strings.
- `SECRET_KEY_BASE=placeholder_for_build_only` in Dockerfile is explicitly a build-time placeholder, not a production secret. The production value is injected via Secret Manager.
- `.env.example` contains empty values only, serving as documentation.

---

## Container Security

### Docker Image Design

**Multi-stage build:** The Dockerfile uses two stages:
1. **Tools stage** (`ubuntu:22.04`): Installs security tools with pinned versions (ZAP 2.15.0, Nuclei 3.2.4, ffuf 2.1.0).
2. **App stage** (`ruby:3.2.2-slim`): Installs Rails application and copies tool binaries from stage 1.

**Current state:** The container runs as root (default). This is common in security scanning containers because several tools require elevated privileges or write to system directories.

### Image Considerations

| Aspect | Current State | Risk Level |
|--------|--------------|------------|
| Base image pinning | `ubuntu:22.04`, `ruby:3.2.2-slim` | Medium -- minor versions float |
| Root user | Running as root | Medium -- mitigated by Cloud Run isolation |
| Tool version pinning | Versions pinned in Dockerfile | Low |
| Image signing | Not implemented | Medium |
| Vulnerability scanning | Not configured | Medium |
| SecLists subset | Only common.txt + directory-list | Low -- reduces image size and attack surface |

### Cloud Run Isolation

Cloud Run provides strong container isolation via gVisor (runsc), which sandboxes the container kernel. This mitigates many risks associated with running as root:
- No access to host kernel
- No access to other containers or workloads
- Network egress restricted to configured targets and APIs
- Ephemeral filesystem -- no persistent state between executions

---

## Network Security

### Cloud Run Network Model

```
+-------------------+
| Cloud Run Job     |
| (gVisor sandbox)  |
+--------+----------+
         |
         |  Egress only (no ingress listeners)
         |
    +----+----+----+----+----+
    |    |    |    |    |    |
    v    v    v    v    v    v
  Target  NVD  EPSS  KEV  Claude  Slack/SMTP
  URLs    API  API   API  API     Webhooks
```

**Key properties:**
- Cloud Run Jobs have no ingress endpoint -- they are triggered by Cloud Scheduler via authenticated HTTP, not exposed to the internet.
- The scanner SA's OAuth token is required to trigger job execution.
- All outbound connections use HTTPS (TLS 1.2+).

### VPC Considerations

**Current state:** The Cloud Run Job runs on the default network with public internet egress.

**For enhanced security:**
- Deploy within a VPC with Cloud NAT for controlled egress.
- Use VPC Service Controls to restrict which GCP APIs the service account can access.
- Implement firewall rules to allowlist only required external endpoints (NVD, EPSS, CISA, Anthropic API, scan targets).
- If scanning internal applications, use VPC connectors for private network access.

---

## Data Handling

### Sensitivity Classification

Scan results contain detailed vulnerability information about target applications. This data is sensitive because it provides a roadmap for exploitation.

| Data Type | Classification | Retention | Storage |
|-----------|---------------|-----------|---------|
| Raw scanner output | High | Ephemeral (scan duration) | Container filesystem (`tmp/scans/`) |
| Findings database | High | Ephemeral (scan duration) | SQLite in container |
| JSON reports | High | 90 days | GCS bucket |
| HTML/PDF reports | High | 90 days | GCS bucket |
| Scan logs | Medium | Ephemeral (container lifetime) | stdout (Cloud Logging) |
| AI assessment data | High | Ephemeral (in findings DB) | SQLite, then in reports |

### Data Lifecycle

1. **Creation:** Scan tools write raw output to `tmp/scans/{scan_id}/{tool}/`.
2. **Processing:** Result parsers normalize findings into the SQLite database.
3. **Enrichment:** CVE intelligence and AI assessments are added to finding records.
4. **Reporting:** Reports generated to `tmp/reports/{scan_id}/`, then uploaded to GCS.
5. **Notification:** Summary (counts only, no finding details) sent via Slack/email.
6. **Destruction:** Container terminates; SQLite database, raw output, and local report files are destroyed. Only GCS-hosted reports persist.
7. **Expiry:** GCS lifecycle policy deletes report objects after 90 days.

### Data in Transit

- All external API calls (NVD, EPSS, CISA KEV, OSV, Anthropic, Slack, SMTP) use HTTPS/TLS.
- GCS uploads use the authenticated Google Cloud Storage client library (TLS).
- SMTP uses port 2525 (STARTTLS via authsmtp.com).

### Data at Rest

- GCS bucket has `uniform_bucket_level_access: true` -- no per-object ACLs, access controlled entirely by IAM.
- SQLite database files are ephemeral and destroyed with the container.
- Reports in GCS are encrypted at rest by default (Google-managed encryption keys).

---

## Report Security

### Signed URLs

Reports stored in GCS are accessed via signed URLs with a 7-day expiry:

```ruby
file.signed_url(expires: expires_in.to_i, method: 'GET')
```

**Properties:**
- URLs are time-limited (7 days from generation).
- URLs are method-restricted (GET only).
- URLs are cryptographically signed using the service account's key.
- The `Report` model tracks `signed_url_expires_at` and exposes `#signed_url_valid?` for validation.

### GCS Bucket Permissions

- `uniform_bucket_level_access: true` prevents per-object public ACLs.
- Only the `pentest-scanner` service account has `roles/storage.objectAdmin`.
- No public access is granted to the bucket.
- Reports are organized by path: `reports/{target_id}/{scan_id}/{filename}`.

### Risks

- Signed URLs, once generated, cannot be revoked before expiry. If a URL is leaked, the report is accessible for up to 7 days.
- Notification messages (Slack, email) may contain signed URLs. Channel/inbox security determines report security.

---

## Authentication for Scanning Targets

### auth_config Design

The `Target` model stores authentication configuration in `auth_config` (JSON):

```ruby
validates :auth_type, inclusion: { in: %w[none basic bearer cookie] }
serialize :auth_config, coder: JSON
```

**Supported authentication types:**

| Type | Configuration | Usage |
|------|--------------|-------|
| `none` | No credentials | Public-facing targets |
| `basic` | `{ "username": "...", "password": "..." }` | HTTP Basic Auth |
| `bearer` | `{ "token": "..." }` | Bearer token (API, JWT) |
| `cookie` | `{ "cookie_name": "...", "cookie_value": "..." }` | Session cookies |

### Security Considerations

**Current state:** `auth_config` is stored as serialized JSON in the SQLite database. In production, the database is ephemeral (destroyed with the container), limiting exposure.

**Risks:**
- During scan execution, credentials exist in plaintext in the SQLite database and in memory.
- If `auth_config` values are logged (e.g., in debug logging), credentials could appear in Cloud Logging.
- `auth_config` values passed to scanner tools may appear in process arguments visible via `/proc`.

**Mitigations in production:**
- SQLite is ephemeral -- credentials are destroyed when the container terminates.
- GCP Secret Manager should be used to store target credentials, with references (not values) in `auth_config`.
- Scanner tools should receive credentials via environment variables or temporary files, not command-line arguments.

---

## Scope Enforcement

### Programmatic Allowlists

The CLAUDE.md and CODE_OF_CONDUCT.md establish that scope constraints must be enforced programmatically, not just documented.

**Current implementation:**
- `Target.scope_config` (JSON) defines the allowlist for scan boundaries.
- `Target.urls` explicitly lists authorized URLs.
- Scanner tools receive only the URLs from the Target record.

**Enforcement points:**
- `ScanOrchestrator#feed_discovered_urls` merges discovered URLs into the target's URL list, but scanners operate only against `target.url_list`.
- ffuf and Nikto discover new URLs but these are filtered through the target's URL scope before being passed to subsequent phases.

### Risks

- **Scope creep via discovery:** If ffuf discovers URLs on different domains and those URLs are blindly added to the target's URL list, subsequent tools may scan unauthorized hosts.
- **Crawler following redirects:** ZAP's spider/crawler may follow redirects to out-of-scope domains.

### Recommended Controls

- Validate all discovered URLs against `scope_config` domain/path allowlists before adding them to the target.
- Configure scanner tools with scope restrictions (ZAP context, Nuclei host filtering).
- Log and alert when out-of-scope URLs are encountered.

---

## Authorization Context

### Ethical and Legal Framework

The platform enforces an authorization-first model:

> All tools in this repo are for **authorized testing only** -- explicit written permission required before use against any target.

**Implementation:**
- The platform is not self-service. Scans are triggered via environment variables (`TARGET_URLS`) or Cloud Scheduler, not a public-facing interface.
- Target records represent authorized engagements. Creating a target is an explicit act requiring credentials and configuration.
- No anonymous or unauthenticated scan initiation path exists.

**Gaps:**
- There is no audit trail linking a scan to the authorization document (e.g., signed scope agreement, ticket reference).
- There is no mechanism to attach or reference authorization documents to Target records.

---

## CI/CD Security

### GitHub Actions

**Secrets management:**
- API keys and credentials stored as GitHub Actions secrets (repository or environment level).
- Secrets are not logged in workflow output (GitHub masks them automatically).
- `WORKFLOW_PAT` used for operations requiring elevated GitHub permissions.

**Workflow security:**
- Actions pinned to specific versions (e.g., `actions/checkout@v4`).
- Pull request workflows run in the context of the PR (limited permissions).
- Deployment workflows require manual approval for production.

### GCP Service Account

**Principle of least privilege:**
- `pentest-scanner` service account has only two IAM roles:
  - `roles/storage.objectAdmin` (scoped to the reports bucket)
  - `roles/secretmanager.secretAccessor` (project-wide -- could be scoped to specific secrets)

**Key rotation:**
- Cloud Run uses workload identity (no exported keys) for the service account.
- If service account keys are exported for CI/CD, they should be rotated on a regular schedule (90 days recommended).

### Container Image Pipeline

```
Source Code (GitHub)
  |
  v
Docker Build (CI/CD or local)
  |
  v
Artifact Registry (pentest/scanner:latest)
  |
  v
Cloud Run Job (pulls image on execution)
```

**Risks:**
- `:latest` tag is mutable. If the registry is compromised, a malicious image could be deployed.
- No image signing or verification is currently implemented.

---

## Supply Chain Security

### Ruby Dependencies

**Gemfile.lock:** All gem versions are pinned via `Gemfile.lock`, checked into version control. `bundle config set --local deployment true` in the Dockerfile ensures exact versions are installed.

**Key dependencies and their security relevance:**

| Gem | Purpose | Supply Chain Risk |
|-----|---------|-------------------|
| `rails ~> 7.1.3` | Application framework | Low (well-maintained, frequent patches) |
| `anthropic ~> 0.3` | Claude API client | Medium (newer gem, smaller maintainer base) |
| `google-cloud-storage ~> 1.44` | GCS access | Low (Google-maintained) |
| `faraday ~> 2.7` | HTTP client | Low (widely used) |
| `grover` | HTML-to-PDF via Puppeteer | Medium (wraps Chromium) |
| `sqlite3 ~> 1.4` | Database driver | Low (well-maintained) |

### Docker Base Images

| Image | Version | Risk |
|-------|---------|------|
| `ubuntu:22.04` | Major version pinned | Medium -- minor updates float |
| `ruby:3.2.2-slim` | Patch version pinned | Low |

### Security Tool Binaries

| Tool | Version | Source | Verification |
|------|---------|--------|-------------|
| OWASP ZAP | 2.15.0 | GitHub Releases | SHA256 not verified |
| Nuclei | 3.2.4 | GitHub Releases | SHA256 not verified |
| sqlmap | HEAD | Git clone (depth 1) | No verification |
| ffuf | 2.1.0 | GitHub Releases | SHA256 not verified |
| Nikto | HEAD | Git clone (depth 1) | No verification |
| SecLists | HEAD | Git clone (depth 1) | No verification |

**Risk:** Tool binaries downloaded via HTTP(S) without checksum verification. A compromised GitHub release or man-in-the-middle attack could inject malicious binaries.

---

## Recommendations for Hardening

### Priority 1: Critical

1. **Verify tool binary checksums in Dockerfile.** Add SHA256 verification for all downloaded binaries (ZAP, Nuclei, ffuf). Pin git-cloned tools (sqlmap, Nikto) to specific commit SHAs rather than HEAD.

2. **Scope enforcement for discovered URLs.** Implement domain/path allowlist validation in `ScanOrchestrator#feed_discovered_urls` before adding discovered URLs to the target. Reject URLs that fall outside `scope_config`.

3. **Prevent credential logging.** Add log filtering to ensure `auth_config` values, API keys, and bearer tokens are never written to logs. Configure Rails log filtering for sensitive parameters.

### Priority 2: High

4. **Run container as non-root.** Create a dedicated user in the Dockerfile and configure tools that require write access to use designated directories. Test all scanner tools under the non-root user.

5. **Pin Docker base images by digest.** Replace `ubuntu:22.04` and `ruby:3.2.2-slim` with digest-pinned references (e.g., `ruby@sha256:abc123...`) to prevent silent base image changes.

6. **Implement image signing.** Use cosign or Docker Content Trust to sign images pushed to Artifact Registry. Verify signatures before Cloud Run execution.

7. **Scope Secret Manager access.** Restrict `roles/secretmanager.secretAccessor` to specific secrets (resource-level IAM) rather than project-wide.

### Priority 3: Medium

8. **Add authorization document tracking.** Extend the `Target` model with fields for authorization reference (document URL, ticket number, expiry date). Block scan execution for targets with expired authorization.

9. **Implement VPC and egress controls.** Deploy Cloud Run Job within a VPC. Use Cloud NAT with egress firewall rules limiting outbound connections to known API endpoints and authorized target addresses.

10. **Add container vulnerability scanning.** Integrate Artifact Registry vulnerability scanning or Trivy in CI/CD to detect known CVEs in the Docker image before deployment.

11. **Use immutable image tags.** Replace `:latest` with content-addressable tags (e.g., Git SHA-based tags) in Cloud Run job configuration. Prevent tag overwriting in Artifact Registry.

12. **Implement signed URL revocation.** Add a mechanism to regenerate or invalidate report signed URLs if a report needs to be retracted. Consider shorter expiry periods (24-48 hours) with on-demand URL refresh.

### Priority 4: Low

13. **AI prompt injection defense.** Sanitize scan result data before including it in Claude API prompts. Strip or escape content that could be interpreted as prompt instructions.

14. **Audit logging.** Implement structured audit logs for scan initiation, target creation, report access, and configuration changes. Ship to a separate, tamper-evident log sink.

15. **Network segmentation for scan targets.** If scanning internal applications, use dedicated VPC connectors with firewall rules that restrict scanner traffic to only the authorized target addresses for each scan.

16. **Dependency update automation.** Configure Dependabot or Renovate for automated security updates to Gemfile dependencies and Docker base images.
