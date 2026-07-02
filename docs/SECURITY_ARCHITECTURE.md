---
title: Security Architecture
---

# Security Architecture Review

**Version:** 3.0
**Last Updated:** 2026-06-28
**Scope:** Security posture of the scanning **engine** in this repository — not the targets it scans.

> **This repository is one component of a larger platform.** It is the scanning *engine*: it executes a scan it is dispatched and exports the results. Target authorization, orchestration, the control plane, result consumption (reporting), the build/supply-chain pipeline, and network controls are **separate systems that are not represented in this repository**. Do not infer the platform's overall security posture from this repo alone — the absence of a control *here* is not evidence the control does not exist; it is most often enforced in a component upstream or downstream of this engine.
>
> This document describes posture at the level of **principle and responsibility**. Operational specifics (identities, project layout, hostnames, image names) are intentionally omitted from this public document.

---

## Threat Model

This addresses risks to the scanning engine. The engine executes offensive security tooling against authorized target URLs and produces vulnerability findings. Notably, it operates with a **minimal secret surface**: it performs **black-box, unauthenticated** scanning **as a matter of policy** — it holds no target credentials and never logs in. It also holds **no third-party API keys**: CVE/exploit enrichment is a downstream concern (removed from this engine in the thin-probe cutover), so no NVD-style key is provisioned here. Even the API-fuzz probe stays inside the boundary — it *discovers* a publicly reachable schema (a schema URL is data, not a credential) rather than authenticating.

### Assets

| Asset | Sensitivity | Notes |
|-------|------------|-------|
| Scan findings (vulnerability details) | High | The primary sensitive asset. Ephemeral on the VM; retained in managed object storage / warehouse under the documented retention policy. |
| Control-plane completion token | Medium | Bearer token for the engine→consumer handoff; held in a managed secret store, never in request bodies or images. The legacy callback was removed (#906); completion is now storage-only (a `status.json` the consumer polls). |
| Source code | Low/Medium | Public repository (intentionally — see below). |

**Not assets for this engine (common misconceptions):**
- **Target credentials** — the engine scans **black-box / unauthenticated as a matter of policy**; it does not log in to targets, performs no authenticated or access-control (BOLA/IDOR) testing, and stores no target credentials. (A latent `auth_config` schema field exists but is **not used** by any scanner.) This shrinks the blast radius: a compromised scanner VM leaks no target logins because it never held any.
- **API schemas are not credentials** — the API-fuzz probe (schemathesis) discovers a *publicly reachable* OpenAPI/GraphQL schema and reports **not-applicable** when none is reachable unauthenticated; it never authenticates to obtain one.
- **Tool/CVE API keys** — no third-party API key is provisioned or held; CVE/exploit enrichment is downstream, out of scope for this engine.

### Threat Actors

| Actor | Motivation | Capability |
|-------|-----------|------------|
| External attacker | Obtain findings to exploit a scanned target | Network access |
| Malicious insider | Run a scan against an unauthorized target | Platform access |
| Supply-chain attacker | Tamper with the scanner's tools or dependencies | Dependency/image tampering |

### Primary Threat Scenarios

1. **Unauthorized scan execution** — a scan is run against a target outside an authorized engagement. *Mitigation lives upstream* (see Scope & Authorization).
2. **Findings exposure** — scan results are accessed by an unauthorized party. *Mitigation:* least-privilege storage IAM + retention/destruction (see Data Handling).
3. **Scanner tool compromise** — a tampered tool binary alters scan behaviour. *Mitigation:* vetted, content-addressed build pipeline (see Supply Chain).

---

## Secrets Management

The engine's secret surface is deliberately small. Secrets are held in a **managed secret store**, fetched at boot, and **never baked into images or placed in request bodies / VM metadata payloads**. CVE enrichment is keyless; the engine holds no target credentials. The only runtime secret is the control-plane completion token (its callback was removed in #906; completion is storage-only via a `status.json`).

---

## Execution & Isolation

Scans run on **single-use, ephemeral VMs** that exist only for the scan's duration:

- **No standing compute and no state between scans.** The VM self-deletes on completion *and* on failure (an exit trap owns teardown); orphans are reaped by an independent backstop.
- **Native (non-container) execution.** The runtime executes the scanner natively; the containerized model has been **removed** (there are no `docker/` assets or `Dockerfile*` in the repo).
- **Dedicated, non-root service identity.** The scan process runs as a purpose-scoped, least-privilege identity — not root, and not a broad/shared identity.
- **Vetted, content-addressed base image.** The VM image is produced by a build pipeline that pins and content-verifies every tool and dependency before placement, and **strips build tooling (compilers, package managers) from the runtime image**. The runtime never installs or compiles anything at boot.

---

## Network Security

```
Single-use VM (scan duration only)
  |  egress only — no ingress listeners
  +--> target URLs (scan tools)
  +--> CVE intelligence sources (enrichment)
  +--> managed storage / warehouse (results)
```

All outbound connections are TLS. The VM exposes no inbound listeners.

---

## Control Plane Security

- **Dispatch authorization is upstream.** A scan reaches this engine only after the orchestration layer has authorized it; the engine does not accept arbitrary self-service scan requests (see Scope & Authorization).
- **Completion handoff** uses bearer-token auth today and is moving to a **storage-only completion signal** (no inbound callback). Replay is bounded by a once-only job identifier validated by the consumer.
- **Cancel signals** are written by the upstream component to a storage path the engine can **read but not write**; storage IAM enforces the boundary.

---

## Data Handling

| Data | Classification | Retention | Storage |
|------|---------------|-----------|---------|
| Raw scanner output | High | Scan duration only | VM filesystem (destroyed with the VM) |
| Normalized findings (working DB) | High | Scan duration only | On-VM, destroyed with the VM |
| Exported findings (JSON) | High | Per documented retention | Managed object storage |
| Findings (warehouse) | High | Per documented retention | Managed warehouse |
| Scan logs | Medium | VM lifetime | Platform logging (credential handling addressed org-wide under SOC 2) |

**Lifecycle:** tools write raw output → parsers normalize → CVE enrichment → export to managed storage → consumer generates reports → **VM self-terminates, destroying all on-VM data** → retention expiry on stored results.

---

## Scope & Authorization

**Authorization is established and enforced *upstream* of this engine.** The scanner is a **dispatched worker**: it executes scans within an **already-authorized scope** and is *not itself the authorization authority* — it lacks the engagement context to make that decision, by design.

- The target and its authorized URL set are fixed by the orchestration layer at dispatch.
- Within an authorized engagement, discovery-expanded URLs (e.g. from content discovery or crawling) remain **bounded by that engagement's scope**; the engine does not widen scope on its own initiative.

> Reading this repo in isolation, one may see a scope field that the scanner does not itself enforce and conclude "scope is unenforced." That conclusion is a layer error: scope/target authorization is enforced **before** a scan is handed to this engine.

---

## Supply Chain Security

- **Ruby dependencies** are pinned via `Gemfile.lock` and **vendored into the image at build time** — the runtime never runs `bundle install` or compiles gems.
- **Tool binaries** are sourced from a **vetted, content-addressed build pipeline** (pinned + content-verified before placement), not ad-hoc runtime downloads. Build tooling is stripped from the runtime image.
- The legacy per-tool download model has been **removed** (no `Dockerfile*`); tools come only from the vetted baked image.

---

## CI/CD Security

- Self-hosted Woodpecker CI; secrets injected via `from_secret:` (never in YAML).
- No arbitrary code execution from PRs; branch protection enforced; **manual approval required for the production promotion**.
- A **pre-publish content lint** blocks operational/identity/topology detail (infra hostnames, service-account emails, private IPs, internal references) from entering this public repository.

---

## Posture Notes & Remaining Hardening

This section is **deliberately not a gap list** — earlier revisions of this document were read (by an automated reviewer) as if every "recommendation" were an open vulnerability. Most such concerns are **handled in components not represented in this repository**:

| Concern | Where it's handled |
|---|---|
| Target-scope / authorization enforcement | **Upstream** orchestration layer (the engine is a worker) |
| Tool binary integrity (pin + content-verify) | **Build pipeline** (vetted, content-addressed; build tooling stripped) |
| Non-root / no-container execution | **Current execution model** (native, dedicated non-root identity) |
| Image provenance / immutability | **Build pipeline** (content-addressed, immutable images) |
| Network egress controls | **Platform networking** (not this repo) |
| Credential log handling | **Addressed org-wide under SOC 2** (and the engine holds no target credentials) |

**Genuinely tracked on this engine's roadmap** (not gating, and none implying an unmitigated credential/authorization exposure):
- Automated rotation of the (soon-retired) completion token.
- Continued retirement of the legacy containerized assets once the native path is fully cut over.

---

*This platform executes offensive security tooling and is for **authorized testing only** — written permission is required before any target is scanned. This document is maintained as a public, posture-level overview; it intentionally omits operational specifics.*
