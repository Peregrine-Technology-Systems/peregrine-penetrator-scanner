#!/usr/bin/env bash
set -euo pipefail

# Post-deploy smoke test: trigger smoke-test profile scan and verify GCS outputs
# Uses 'smoke-test' profile: canned findings, stubbed reporter calls, validates full pipeline
# Runs on staging and production only (development uses interactive VM)

BRANCH="${CI_COMMIT_BRANCH}"

case "$BRANCH" in
  staging)     GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}"; IMAGE_TAG="staging" ;;
  main)        GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}"; IMAGE_TAG="production" ;;
  *)           echo "No smoke test for branch: $BRANCH (staging/main only)"; exit 0 ;;
esac

GCS_BUCKET="${GCP_PROJECT}-pentest-reports"
POLL_INTERVAL=15
MAX_WAIT=180  # 3 minutes max for smoke-test profile

echo "=== Smoke Test: ${BRANCH} ==="

# Launch a smoke-test scan VM (canned findings + stubbed reporter calls)
scripts/woodpecker/trigger-scan.sh "${BRANCH}" smoke-test "${IMAGE_TAG}"

VM_PREFIX="pentest-scan-${BRANCH}-"
echo "Waiting for smoke scan VM to complete..."

elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  RUNNING_VMS=$(gcloud compute instances list \
    --filter="name~${VM_PREFIX} AND status=RUNNING" \
    --project="${GCP_PROJECT}" \
    --format="value(name)" 2>/dev/null || echo "")

  if [ -z "$RUNNING_VMS" ]; then
    echo "Smoke VM terminated after ${elapsed}s — checking results..."
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

  # Verify scan completed successfully (not failed/crashed)
  SCAN_STATUS=$(python3 -c "
import json, sys
d = json.load(open('$TMPFILE'))
s = d.get('summary', {})
# Check both top-level status and summary.status
status = d.get('status') or s.get('status', '')
print(status)
" 2>/dev/null || echo "")

  if [ "$SCAN_STATUS" = "completed" ]; then
    echo "  PASS: scan status=completed"
  elif [ -n "$SCAN_STATUS" ]; then
    echo "  FAIL: scan status=${SCAN_STATUS} (expected completed)"
    ERRORS=$((ERRORS + 1))
  else
    echo "  WARN: no status field found in results"
  fi

  # Check smoke test results in summary
  python3 -c "
import json, sys
d = json.load(open('$TMPFILE'))
s = d.get('summary', {})
print(f\"  Schema: v{d.get('schema_version')}\")
if s.get('smoke_test'):
    checks = s.get('checks', {})
    passed = s.get('passed', False)
    print(f\"  Smoke test: {'PASSED' if passed else 'FAILED'}\")
    for check, status in checks.items():
        print(f\"    {check}: {status}\")
    if not passed:
        sys.exit(1)
else:
    print(f\"  Findings: {s.get('total_findings', 'unknown')}\")
" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "  FAIL: smoke test checks did not pass"
    ERRORS=$((ERRORS + 1))
  fi

  rm -f "$TMPFILE"
else
  echo "  FAIL: No JSON results found in ${RESULTS_PREFIX}"
  ERRORS=$((ERRORS + 1))
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
