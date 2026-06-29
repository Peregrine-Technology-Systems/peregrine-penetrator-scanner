# Penetrator Probe Output Contract

| | |
|---|---|
| **Status** | Draft for review |
| **Contract version** | `2.0` (target) — supersedes the flat `1.x` finding shape |
| **Owner** | Scanner (this repository) |
| **Blessed by** | Architecture (review/sign-off; ownership stays with the scanner) |
| **Consumers** | the analysis service, and through it the reporting service |

This is the **canonical contract for what a Penetrator probe emits**. The scanner houses the probes and produces the findings, so the scanner owns this contract; architecture blesses it. Consumers conform to it — they do not redefine it.

It is written to **evolve**: the scanner moves faster than its consumers, so the contract is shaped so the scanner can *add* without breaking a consumer that lags behind.

---

## 1. What a probe is, and what it does not do

A **probe** runs one security tool against an authorized target, parses its output, and emits findings in the shape below. That is the whole job. A probe **does not** enrich, score, deduplicate across scans, prioritize, or correlate — those are the analysis service's responsibilities. The clean line:

- **Probe provides:** the raw, as-observed signal — locator, every identifier the tool asserted, the tool's own scores, evidence, and a pointer to the lossless raw payload.
- **The analysis service adds:** authoritative scoring, cross-scan/cross-probe deduplication, prioritization, temporary identifiers, and recent-exploit context — **additively, in a namespaced block, never overwriting the probe's signal.**

The reference roster is the nine open-source tools in `app/services/scanners/`. Custom first-party probes will follow; the contract is designed so they need **no schema change** to join.

---

## 2. Design principles (the flexibility rules)

1. **Thin stable core + open vocabularies + an extension bucket.** A small set of always-present fields; everything probe-specific is expressible without a schema change.
2. **The document is canonical; storage is a thin index.** The finding JSON is the source of truth. Databases promote only a few fields to columns for search/partition (§9). Adding a probe field never adds a column.
3. **Additive-only by default.**
   - **MINOR** = adding a field, a `finding_type`, a `location.kind`, an `identifiers[].type`, or a vocabulary value. Backward-compatible.
   - **MAJOR** = removing or repurposing a *populated* field.
4. **Consumers MUST ignore unknown fields.** This is what lets the scanner run ahead: a consumer built for an older MINOR keeps working against newer output.
5. **Open vocabularies, not closed enums.** `probe`, `source_tool`, `finding_type`, `location.kind`, and `identifiers[].type` are documented-but-open strings — a new or custom probe, identifier type, or locator kind is zero schema change. The **only** closed, stable enum is the normalized `severity` set (§6).
6. **`ext` is the run-ahead seam.** A probe may emit anything probe-specific under `ext`; consumers ignore it until a field earns promotion into the core.

---

## 3. The finding object

```jsonc
{
  // ---- provenance (always present) ----
  "id": "uuid",
  "scan_id": "uuid",
  "detected_at": "2026-06-29T14:03:00Z",
  "probe": "web-dast",            // OPEN vocab — see §5
  "source_tool": "zap",           // OPEN vocab
  "tool_check_id": "40012",       // native rule/template/plugin id; nullable

  // ---- classification (probe-provided) ----
  "finding_type": "vulnerability",// OPEN vocab — see §5
  "severity": "high",             // normalized, CLOSED enum; nullable for non-vuln — see §6
  "severity_source": "High",      // the tool's own severity string, verbatim; nullable
  "confidence": "medium",         // nullable
  "verified": true,               // nullable (e.g. secret verification)
  "title": "SQL Injection",
  "description": "…",             // nullable

  // ---- polymorphic locator (replaces flat url/parameter) ----
  "location": {
    "kind": "web",                // OPEN vocab — web | network | file | package | asset | …
    // shape depends on kind; consumers read what they know, ignore the rest:
    "url": "https://…", "method": "GET", "parameter": "id"
    //   network → host, port, protocol
    //   file    → path, line, commit
    //   package → name, version, ecosystem      (also mirrored in component{})
    //   asset   → domain, ip, record_type
  },

  // ---- identifiers: OPEN list — preserve ALL the tool asserted ----
  "identifiers": [
    { "type": "cve",  "value": "CVE-2021-1234" },
    { "type": "cwe",  "value": "CWE-89" }
    //  ghsa | cpe | osvdb | … = a new list entry, never a schema change
  ],

  // ---- component context (SCA / TLS / CMS); nullable ----
  "component": { "name": "jquery", "version": "1.7.1", "ecosystem": "npm", "cpe": null },

  // ---- tool-REPORTED scores (raw probe signal; nullable) ----
  "scores": {
    "cvss_score": 9.8, "cvss_vector": "CVSS:3.1/…", "epss_score": 0.42
  },

  // ---- evidence + lossless raw ----
  "evidence": { "request": "…", "response": "…", "matcher": "…" },
  "raw_ref": "gs://…/raw/<id>.json", // pointer to the lossless raw tool payload; nullable

  "fingerprint": "sha256:…",      // scanner-computed identity hint; nullable

  // ---- the run-ahead seam ----
  "ext": { }                      // probe-specific, opaque to consumers until promoted
}
```

### Analysis-service output (NOT written by probes)

The analysis service writes its results into a **separate, namespaced block** so the probe's raw signal is never mutated:

```jsonc
{
  "enrichment": {
    "cvss_score": 9.8, "cvss_vector": "…",   // authoritative, may differ from scores.*
    "epss_score": 0.42, "kev_known_exploited": true,
    "priority": "P0", "temp_id": "PEN-TEMP-…",
    "recent_exploits": [ … ], "dedup_cluster_id": "…"
  }
}
```

`scores.*` is "what the tool said." `enrichment.*` is "what the analysis service concluded." Both coexist; neither overwrites the other.

---

## 4. Field reference

| Field | Type | Set by | Required | Notes |
|---|---|---|---|---|
| `id` | uuid | probe | ✓ | per-finding |
| `scan_id` | uuid | probe | ✓ | correlation |
| `detected_at` | ISO-8601 | probe | ✓ | partition key (§9) |
| `probe` | string (open) | probe | ✓ | logical probe name |
| `source_tool` | string (open) | probe | ✓ | underlying tool |
| `tool_check_id` | string | probe | — | native rule/template/plugin id |
| `finding_type` | string (open) | probe | ✓ | §5 |
| `severity` | enum (closed) | probe | — | normalized; null for non-vuln |
| `severity_source` | string | probe | — | tool's verbatim severity |
| `confidence` | string | probe | — | tool's confidence if any |
| `verified` | bool | probe | — | e.g. secret verification |
| `title` | string | probe | ✓ | |
| `description` | string | probe | — | |
| `location` | object | probe | ✓ | typed by `kind` |
| `identifiers[]` | list | probe | — | preserve all; never truncate |
| `component` | object | probe | — | SCA/TLS/CMS |
| `scores` | object | probe | — | tool-reported scores |
| `evidence` | object | probe | — | structured snippets |
| `raw_ref` | string (uri) | probe | — | lossless raw payload pointer |
| `fingerprint` | string | probe | — | identity hint |
| `ext` | object | probe | — | probe-specific overflow |
| `enrichment` | object | analysis service | — | additive; never set by a probe |

---

## 5. The nine reference probes

Grounded in the current parsers (`app/services/result_parsers/`). This is how each tool maps onto the contract.

| Probe | `source_tool` | `finding_type` | `location.kind` | `tool_check_id` from | tool identifiers | `scores` | notable |
|---|---|---|---|---|---|---|---|
| Web DAST | `zap` | vulnerability / misconfiguration | web | pluginId | cwe | — | confidence, description |
| Template / CVE | `nuclei` | vulnerability | web | template-id | cve, cwe | cvss_score, cvss_vector, epss_score | matcher, curl_command |
| Injection | `sqlmap` | vulnerability | web | technique | cwe | — | payload, dbms |
| Content discovery | `ffuf` | exposure / informational | web | — | — | — | status_code, length |
| Server misconfig | `nikto` | misconfiguration | web | osvdb/id | cwe | — | message |
| TLS / SSL | `testssl` | misconfiguration | **network** | testssl id | cve(s), cwe | — | host, port, protocol |
| SCA / dependency | `retirejs` | outdated-component | **package** | — | cve(s), cwe | — | component, version |
| Secrets | `trufflehog` | **secret** | **file** | DetectorName | — | — | verified, redacted |
| Asset discovery | `amass` | **asset** | **asset** | — | — | — | feeds discovery; may emit asset findings |

**`finding_type` vocabulary (open):** `vulnerability`, `misconfiguration`, `exposure`, `secret`, `outdated-component`, `asset`, `informational`.

**Lossless wins this shape unlocks (vs. the flat `1.x` model):**
- `identifiers[]` preserves **every** CVE/CWE — today `retirejs` and `testssl` keep only the first and discard the rest.
- `location.kind=network`/`package`/`file` gives `testssl` (host+port), `retirejs` (component@version), and `trufflehog` (file:line:commit — currently uncaptured) real homes instead of a synthesized URL or an untyped `evidence` blob.
- `raw_ref` lets the analysis service re-interpret a finding as its logic improves, without a re-scan.

---

## 6. Severity

`severity` is the **one closed, stable enum**: `critical | high | medium | low | info`, or **`null`** when the finding has no meaningful severity (an `asset` or `informational` finding — e.g. a discovered subdomain).

The tool's own severity string is preserved verbatim in `severity_source` (e.g. Nuclei's `unknown`, testssl's raw level), so the normalization is never lossy. Each probe documents its `severity_source → severity` mapping in its parser.

---

## 7. Identifiers

`identifiers[]` is an **open list of `{type, value}`**. Preserve **all** identifiers the tool asserts — never collapse to one. Known types: `cve`, `cwe`, `ghsa`, `cpe`, `osvdb`. A new type is a new entry, not a schema change. A finding with **no** official identifier is normal (misconfig, secret, asset) — the analysis service may assign a temporary internal id in `enrichment.temp_id`.

---

## 8. Versioning authority

- The **envelope** carries the authoritative `schema_version` for the whole result set. A consumer reads the envelope version to know how to interpret every finding in it.
- A per-finding `schema_version` may appear in storage rows (§9) as a denormalized copy for query convenience; the envelope value is authoritative if they ever differ.
- Version lives in the **payload**, never in a CloudEvent `type` string.
- Bump rules per §2.3 (MINOR additive / MAJOR removing-or-repurposing).

---

## 9. Storage mapping — document canonical, thin index

The finding JSON is stored **whole** (BigQuery native `JSON`, or Postgres `JSONB`). Only a deliberately small set of fields is promoted to columns — and a field earns a column **only** when there is a proven query, partition, or join need. Adding probe fields **never** adds a column.

| Column | Why it earns a column |
|---|---|
| `finding_id` | primary key |
| `scan_id` | join / correlation |
| `fingerprint` | dedup lookups |
| `detected_at` | time-partition key |
| `severity` | dominant filter |
| `finding_type` | filter (vuln vs asset vs secret …) |
| `probe` / `source_tool` | filter by probe |
| `schema_version` | tells you how to read the JSON |
| **`finding_json`** | the full finding — source of truth |

Deliberately **not** columns: `location`, `identifiers[]`, `component`, `scores`, `evidence`, `confidence`, `verified`, `tool_check_id`, `ext`, and the analysis service's `enrichment`. They live in `finding_json` and are queryable via `JSON_VALUE`/`JSON_QUERY`. If a real "all findings for CVE-X" query pattern appears, add **one** denormalized `primary_cve_id` search column then — not a column per identifier type, and not preemptively.

This same shape — document + thin index — holds across the local store, BigQuery, and a future Postgres `JSONB` store.

---

## 10. Envelope notes

- **Failed tools stay visible.** A zero-finding scan with a failed tool is *partial*, not clean. `tool_chain.executed` is the canonical per-tool execution record; nullable `exit_code`/`findings_count` for a failed tool are explicit, not omitted.
- **Planned config is opaque.** Heterogeneous `planned[].config` is preserved as opaque metadata.
- **Additive scanner metadata is optional, never a prerequisite.** The envelope `metadata` carries additive operational context — e.g. the compute substrate (#970) and VM wall-clock timing (#954). These are useful downstream but **must not become prerequisites for vulnerability enrichment**: a consumer reads them if present and ignores them if absent. They are envelope-level, not finding-level, and never gate analysis.

## 11. Conformance fixture (the contract-test target)

The contract ships with a **representative reference fixture** that the scanner emits and consumers test against. Requirements:

- At least one populated finding **with a direct CVE** and at least one **without** any official identifier.
- At least one finding from each major tool class (web / network / package / file / asset locator kinds).
- The no-CVE finding carries enough context to be classified later: `source_tool` + `tool_check_id`, `location`/`component`, normalized `title`/`severity`/`confidence`, `evidence`, and `raw_ref`.
- At least one failed-tool entry in `tool_chain.executed`, to prove partial scans stay distinguishable from clean ones.

The fixture is the stable target the analysis service writes its contract test against — it lets the consumer validate against the shape without pushing any analysis logic back into the probe.

### Synthetic corpus (bootstrap material)

A larger deterministic synthetic corpus ships alongside the fixture for cold-start / Knowledge-Loop bootstrapping:

- **Location:** `spec/fixtures/synthetic_corpus/` — `manifest.json`, `realistic.json`, `perturbed.json`.
- **Generator:** `spec/support/synthetic_corpus.rb` (seeded, reproducible — re-running yields byte-identical output).
- **Conformance test:** `spec/contract/probe_contract_spec.rb`.
- **Two labelled series:** `realistic` (100 findings across all nine probes, with multi-identifier and duplicate cases) and `perturbed` (30 out-of-distribution findings, each `ext.synthetic.perturbation = <type>` + `label = escalate` — the "exceeds the deterministic DSL, escalate" class, **not** garbage).
- **Not ground truth.** This is synthetic bootstrap material; a model trained on it risks learning the generator, not the world. Replace with a real corpus as it accrues.

---

## 12. How to evolve this contract

- **Add a field to a finding:** put it in `ext` first; promote to core (MINOR) once it's stable and a consumer needs it.
- **Add a probe (incl. custom):** pick `probe`/`source_tool` strings, a `finding_type`, and a `location.kind`; emit the core fields. No schema change.
- **Add an identifier type / locator kind / finding_type:** document the new vocabulary value (MINOR).
- **Remove or repurpose a populated field:** MAJOR — coordinate with consumers first.

The flat `1.x` fields (`url`, `parameter`, `cwe_id`, `cve_id`, `cvss_score`, …) are superseded by `location`/`identifiers[]`/`scores` and are **deprecated**; they are removed at the `2.0` cutover.

---

## See also

- `docs/schema_versioning.md` — the envelope version contract and MINOR/MAJOR rules.
- Issue #971 — preserve raw finding context for downstream enrichment (the requirement this contract satisfies).
