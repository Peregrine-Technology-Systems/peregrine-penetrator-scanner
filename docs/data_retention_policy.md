# Data Retention Policy

How the Penetrator scanner handles scan data over its lifecycle, and what Peregrine Technology Systems retains.

## Principle

**Peregrine Technology Systems does not retain the specific records of a scan once the result has been delivered to the customer.** The vulnerability data a scan produces — findings, evidence, the full result envelope — belongs to the customer. Peregrine retains only a minimal **audit record** that a scan occurred.

## What is retained, and what is not

| Data | Retained by Peregrine? | Notes |
|------|:--:|------|
| **Vulnerability / scan findings** (severity, title, CVE, URLs, evidence) | **No** | Delivered to the customer, then deleted. Not kept after delivery. |
| **Full result envelope** (the exported scan JSON) | **No** | Same — a delivery artifact, not a Peregrine record. |
| **Scan audit record** — that a site was scanned, scan **start/end time**, and **scan type** | **Yes** | Minimal metadata for compliance/traceability. Contains **no** vulnerability detail. |

## Who deletes the scan records

**The scanner does not retain or purge anything.** Its role is bounded: run the security tools against an authorized target, normalize/enrich the findings, **export** the result to managed storage for delivery, and emit audit events. It holds no long-term store and runs no retention job.

Deletion of the specific scan records once they have been **delivered to the customer** is performed by the **downstream components** of the Penetrator product (orchestration / reporting / delivery) — they own delivery, so they own the post-delivery deletion. That logic is intentionally **not present in this repository**.

## On-VM data

Each scan runs on a **single-use VM** that **self-deletes** when the scan finishes (success or failure). All on-VM working data — raw tool output, temporary files, the local copy of results — is destroyed with the VM. Nothing scan-specific persists on compute.

## SOC 2 retention (18 months) applies to internal audit logs only

Peregrine's **internal audit logs** are retained for **18 months** in support of SOC 2 Type II / ISO 27001 (see [audit_logging.md](audit_logging.md)). This 18-month retention covers the **audit record** described above — the fact of the scan, its timing, and its type — and explicitly **excludes vulnerability / finding data**, which is not retained after delivery. The 18-month window is about *internal compliance logging*, not about keeping scan results.

## Summary

- Scanner: exports results for delivery; retains/purges nothing.
- Downstream: delivers to the customer, then deletes the specific scan records.
- Peregrine keeps: a minimal audit record (site scanned, start/end, scan type) for 18 months — no vulnerability data.
- On-VM data: destroyed when the single-use VM self-deletes.
