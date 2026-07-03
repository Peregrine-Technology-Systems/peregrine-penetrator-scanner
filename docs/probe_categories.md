# Probe Categories — Types of Testing

A high-level view of the ten probes in this repo, grouped by the *type of
security testing* each performs. Every entry reflects the actual scanner
implementation (`app/services/scanners/*_scanner.rb`) and the probe-contract
values each emits (`probe` / `finding_type`, per `docs/probe_contract.md`).

> The scanner is a **thin probe** in a fleet. These ten are standard OSS tools;
> first-party custom probes come later. Enrichment, dedup, and prioritization are
> owned downstream by the Analyzer, not by the probes here.

## Testing posture — black-box, unauthenticated (policy)

The fleet establishes vulnerabilities on a **black-box basis, without logging in.**
**We do not perform authenticated testing as a matter of policy.** No provisioned
credentials, no authenticated sessions, no access-control (BOLA/IDOR) testing that
requires acting as a logged-in user. Every probe below runs against the target
exactly as an unauthenticated external party would see it. This is a deliberate
scope choice, not a limitation to be worked around.

---

## 1. Attack-surface discovery / reconnaissance

*Map what's reachable before testing it — expands the target surface for later phases.*

| Probe | What it does | Emits |
|---|---|---|
| **amass** | Passive subdomain enumeration — discovers hostnames/assets belonging to the target | `discovered_urls` (feeds surface expansion, not a finding) |
| **ffuf** | Content/path discovery — brute-forces hidden directories, files, and endpoints from a wordlist | `probe: content-discovery` → `exposure` |

## 2. Web-application dynamic testing (DAST)

*Actively exercise the running application to find exploitable flaws.*

| Probe | What it does | Emits |
|---|---|---|
| **ZAP** | Full DAST — spider + passive baseline, optional active attack (XSS, headers, injection classes, etc.) | `probe: web-dast` → `vulnerability` |
| **sqlmap** | Deep, focused SQL-injection detection & exploitation | `probe: injection` → `vulnerability` |
| **nikto** | Web-server misconfigurations, dangerous default files/CGIs, unsafe options | `probe: server-misconfig` → `misconfiguration` |

## 3. Known-vulnerability / signature matching

*Match the target against a catalogue of already-known CVEs and templates.*

| Probe | What it does | Emits |
|---|---|---|
| **nuclei** | Template-driven CVE & misconfiguration matching (community + custom templates) | `probe: template-cve` → `vulnerability` |
| **retire.js** | Software-composition analysis — flags known-vulnerable JavaScript library versions | `probe: sca` → `outdated-component` |

## 4. Transport / cryptography posture

*Assess the security of the encrypted channel.*

| Probe | What it does | Emits |
|---|---|---|
| **testssl.sh** | TLS/SSL analysis — protocols, cipher suites, certificate, known TLS vulnerabilities | `probe: tls` → `misconfiguration` |

## 5. Secrets / sensitive-data exposure

*Find credentials that shouldn't be exposed.*

| Probe | What it does | Emits |
|---|---|---|
| **trufflehog** | Scans page source + fetched files for hardcoded secrets (API keys, private keys, tokens) | `probe: secrets` → `secret` |

## 6. API testing

*Exercise a declared API surface against its own contract.*

| Probe | What it does | Emits |
|---|---|---|
| **schemathesis** | Unauthenticated, schema-driven API fuzzing — auto-discovers a *publicly reachable* OpenAPI/GraphQL schema and fuzzes every operation it declares (server errors, response-schema violations, status/method conformance) | `probe: api-fuzz` → `vulnerability` (5xx) / `misconfiguration` (conformance) |

---

## The shape at a glance

- **6 categories** across the ten probes.
- **Recon (2)** feed → **DAST (3)** + **known-vuln matching (2)** test the app →
  **crypto (1)**, **secrets (1)**, and **API testing (1)** cover three orthogonal
  exposure classes.
- Coverage spans the layers well: network/transport (testssl), web app
  (zap/sqlmap/nikto), dependencies (retire.js), known-CVE surface (nuclei), and
  data leakage (trufflehog) — with amass/ffuf widening the surface all the others test.

### Notes, scope boundaries & roadmap

- **ffuf** straddles recon and exposure — it discovers surface *and* reports exposed
  content as findings. It's filed under recon here but earns a place in either.
- **Out of scope by policy — authentication / authorization / access-control testing.**
  BOLA/IDOR, privilege escalation, and broken-function-level-auth testing all require
  acting as a logged-in user with provisioned credentials. Per the black-box,
  unauthenticated posture above, **we do not do this** — it is a deliberate scope
  decision, not a gap to be filled. The credential-free slice (detecting *missing*
  authentication and exposed/unauth-reachable surface) is already covered by
  nuclei / ffuf / nikto / zap surfacing exposures.
- **Delivered — unauthenticated API-schema fuzzing (Category 6, shipped v1.5.0).**
  The fleet's first API-testing coverage: **schema-driven API fuzzing** (schemathesis)
  runs **unauthenticated** against a publicly reachable OpenAPI/GraphQL schema. A
  schema-source URL is data, not a credential, so this stays inside the black-box
  boundary; when no schema is reachable unauthenticated it is honestly *not-applicable*
  rather than logging in. (#1018)

---

## Probe → category quick reference

| Probe | Category | `probe` | `finding_type` |
|---|---|---|---|
| amass | Recon | *(discovered_urls)* | *(surface expansion)* |
| ffuf | Recon / Exposure | content-discovery | exposure |
| zap | DAST | web-dast | vulnerability |
| sqlmap | DAST | injection | vulnerability |
| nikto | DAST | server-misconfig | misconfiguration |
| nuclei | Known-vuln matching | template-cve | vulnerability |
| retire.js | Known-vuln matching (SCA) | sca | outdated-component |
| testssl.sh | Transport / crypto | tls | misconfiguration |
| trufflehog | Secrets exposure | secrets | secret |
| schemathesis | API testing | api-fuzz | vulnerability / misconfiguration |
