#!/usr/bin/env bash
set -euo pipefail

# Post-deploy smoke test: trigger a quick scan and verify JSON + PDF outputs
# Polls for VM self-termination, then validates GCS artifacts

BRANCH="${CI_COMMIT_BRANCH}"

case "$BRANCH" in
  development) GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}"; IMAGE_TAG="latest" ;;
  staging)     GCP_PROJECT="${GCP_PROJECT_STG:?GCP_PROJECT_STG not set}"; IMAGE_TAG="staging" ;;
  main)        GCP_PROJECT="${GCP_PROJECT_PRD:?GCP_PROJECT_PRD not set}"; IMAGE_TAG="production" ;;
  *)           echo "No smoke test for branch: $BRANCH"; exit 0 ;;
esac

GCS_BUCKET="${GCP_PROJECT}-pentest-reports"
POLL_INTERVAL=30
MAX_WAIT=900  # 15 minutes max for quick profile

echo "=== Smoke Test: ${BRANCH} ==="

# Launch a quick scan VM
scripts/woodpecker/trigger-scan.sh "${BRANCH}" quick "${IMAGE_TAG}"

VM_PREFIX="pentest-scan-${BRANCH}-"
echo "Waiting for scan VM to complete..."

elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  RUNNING_VMS=$(gcloud compute instances list \
    --filter="name~${VM_PREFIX} AND status=RUNNING" \
    --project="${GCP_PROJECT}" \
    --format="value(name)" 2>/dev/null || echo "")

  if [ -z "$RUNNING_VMS" ]; then
    echo "Scan VM terminated after ${elapsed}s — checking results..."
    break
  fi

  echo "  VM still running (${elapsed}s elapsed)..."
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [ "$elapsed" -ge "$MAX_WAIT" ]; then
  echo "ERROR: Smoke test timed out after ${MAX_WAIT}s"
  exit 1
fi

sleep 5  # GCS propagation

echo "--- Checking GCS for results ---"
RESULTS_PREFIX="gs://${GCS_BUCKET}/scan-results/"
ERRORS=0

# Check for versioned JSON export
echo "Checking JSON results..."
JSON_FILES=$(gsutil ls -r "${RESULTS_PREFIX}**/scan_results.json" 2>/dev/null | tail -1 || echo "")
if [ -n "$JSON_FILES" ]; then
  echo "  PASS: JSON found: ${JSON_FILES}"

  TMPFILE=$(mktemp)
  gsutil cp "$JSON_FILES" "$TMPFILE" 2>/dev/null

  for key in schema_version metadata summary findings; do
    if python3 -c "import json,sys; d=json.load(open('$TMPFILE')); assert '$key' in d" 2>/dev/null; then
      echo "  PASS: JSON has '${key}' key"
    else
      echo "  FAIL: JSON missing '${key}' key"
      ERRORS=$((ERRORS + 1))
    fi
  done

  python3 -c "
import json, sys
d = json.load(open('$TMPFILE'))
s = d.get('summary', {})
print(f\"  Schema: v{d.get('schema_version')}\")
print(f\"  Findings: {s.get('total_findings', 'unknown')}\")
print(f\"  Severity: {s.get('by_severity', {})}\")
" 2>/dev/null || echo "  WARN: Could not parse JSON summary"

  rm -f "$TMPFILE"
else
  echo "  FAIL: No JSON results found in ${RESULTS_PREFIX}"
  ERRORS=$((ERRORS + 1))
fi

# Check for PDF report
echo "Checking PDF report..."
PDF_FILES=$(gsutil ls -r "${RESULTS_PREFIX}**/*.pdf" 2>/dev/null | tail -1 || echo "")
if [ -n "$PDF_FILES" ]; then
  echo "  PASS: PDF found: ${PDF_FILES}"
  PDF_SIZE=$(gsutil stat "$PDF_FILES" 2>/dev/null | grep "Content-Length" | awk '{print $2}' || echo "0")
  if [ "${PDF_SIZE:-0}" -gt 1024 ]; then
    echo "  PASS: PDF size ${PDF_SIZE} bytes (> 1KB)"
  else
    echo "  WARN: PDF size ${PDF_SIZE} bytes — may be empty"
  fi
else
  echo "  FAIL: No PDF report found in ${RESULTS_PREFIX}"
  ERRORS=$((ERRORS + 1))
fi

# Check for HTML report
echo "Checking HTML report..."
HTML_FILES=$(gsutil ls -r "${RESULTS_PREFIX}**/*.html" 2>/dev/null | tail -1 || echo "")
if [ -n "$HTML_FILES" ]; then
  echo "  PASS: HTML found: ${HTML_FILES}"
else
  echo "  WARN: No HTML report found (non-blocking)"
fi

echo ""
echo "=== Smoke Test Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: All checks passed for ${BRANCH}"
  exit 0
else
  echo "FAIL: ${ERRORS} check(s) failed for ${BRANCH}"
  exit 1
fi
