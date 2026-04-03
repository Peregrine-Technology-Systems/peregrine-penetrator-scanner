#!/usr/bin/env bash
set -euo pipefail

# Smoke test for trigger_scan Cloud Function
# Verifies the function accepts request params, launches a VM, and produces GCS artifacts
#
# Usage: smoke-test-cloud-function.sh [environment]
#   environment: staging | production (default: staging)
#
# Requires: gcloud auth (service account with Cloud Functions Invoker role)

ENV="${1:-staging}"

case "$ENV" in
  staging)     GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}" ;;
  production)  GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}" ;;
  *)           echo "Unknown environment: $ENV (staging or production)"; exit 1 ;;
esac

GCS_BUCKET="${GCP_PROJECT}-pentest-reports"
REGION="${GCP_REGION:-us-central1}"
SCAN_UUID="smoke-cf-$(date +%s)"
MAX_WAIT=180  # 3 minutes for smoke-test profile
POLL_INTERVAL=15
ERRORS=0

echo "=== Cloud Function Smoke Test: ${ENV} ==="

# 1. Get the function URL
FUNCTION_URL=$(gcloud functions describe trigger_scan \
  --region="${REGION}" \
  --project="${GCP_PROJECT}" \
  --format='value(httpsTrigger.url)' 2>/dev/null || echo "")

if [ -z "$FUNCTION_URL" ]; then
  echo "FAIL: trigger_scan Cloud Function not found in ${GCP_PROJECT}/${REGION}"
  exit 1
fi
echo "Function URL: ${FUNCTION_URL}"

# 2. POST with smoke-test params
echo "Triggering smoke-test scan via Cloud Function..."
IDENTITY_TOKEN=$(gcloud auth print-identity-token --audiences="${FUNCTION_URL}" 2>/dev/null || echo "")

RESPONSE=$(curl -sf -X POST "${FUNCTION_URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${IDENTITY_TOKEN}" \
  -d "{
    \"profile\": \"smoke-test\",
    \"scan_uuid\": \"${SCAN_UUID}\",
    \"target_url\": \"smoke-test://internal\",
    \"target_name\": \"Smoke Test\",
    \"scan_mode\": \"${ENV}\",
    \"image_tag\": \"${ENV}\"
  }" 2>&1) || {
  echo "FAIL: Cloud Function returned error"
  echo "  Response: ${RESPONSE}"
  exit 1
}

# 3. Verify JSON response
STATUS=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
RETURNED_UUID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('scan_uuid',''))" 2>/dev/null || echo "")
INSTANCE_NAME=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('instance_name',''))" 2>/dev/null || echo "")

if [ "$STATUS" = "accepted" ]; then
  echo "  PASS: status=accepted"
else
  echo "  FAIL: expected status=accepted, got: ${STATUS}"
  ERRORS=$((ERRORS + 1))
fi

if [ "$RETURNED_UUID" = "$SCAN_UUID" ]; then
  echo "  PASS: scan_uuid matches"
else
  echo "  FAIL: scan_uuid mismatch (sent=${SCAN_UUID}, got=${RETURNED_UUID})"
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$INSTANCE_NAME" ]; then
  echo "  PASS: instance_name=${INSTANCE_NAME}"
else
  echo "  FAIL: no instance_name in response"
  ERRORS=$((ERRORS + 1))
fi

# 4. Wait for VM to complete and self-terminate
echo "Waiting for smoke VM to complete..."
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  RUNNING_VMS=$(gcloud compute instances list \
    --filter="name=${INSTANCE_NAME} AND status=RUNNING" \
    --project="${GCP_PROJECT}" \
    --format="value(name)" 2>/dev/null || echo "")

  if [ -z "$RUNNING_VMS" ]; then
    echo "  VM terminated after ${elapsed}s"
    break
  fi

  echo "  VM still running (${elapsed}s elapsed)..."
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [ "$elapsed" -ge "$MAX_WAIT" ]; then
  echo "  FAIL: VM did not terminate within ${MAX_WAIT}s"
  ERRORS=$((ERRORS + 1))
fi

sleep 5  # GCS propagation

# 5. Check GCS artifacts
echo "Checking GCS for results..."
RESULTS_PREFIX="gs://${GCS_BUCKET}/scan-results/"
JSON_FILES=$(gsutil ls -r "${RESULTS_PREFIX}**/${SCAN_UUID}/**/scan_results.json" 2>/dev/null | tail -1 || echo "")

if [ -z "$JSON_FILES" ]; then
  # Broader search — scan_uuid may be in a different path structure
  JSON_FILES=$(gsutil ls -r "${RESULTS_PREFIX}**/scan_results.json" 2>/dev/null | grep "${SCAN_UUID}" | tail -1 || echo "")
fi

if [ -n "$JSON_FILES" ]; then
  echo "  PASS: JSON results found: ${JSON_FILES}"

  TMPFILE=$(mktemp)
  gsutil cp "$JSON_FILES" "$TMPFILE" 2>/dev/null

  # Verify required keys exist
  for key in schema_version metadata summary findings; do
    if python3 -c "import json,sys; d=json.load(open('$TMPFILE')); assert '$key' in d" 2>/dev/null; then
      echo "  PASS: JSON has '${key}' key"
    else
      echo "  FAIL: JSON missing '${key}' key"
      ERRORS=$((ERRORS + 1))
    fi
  done

  # Verify scan completed (not failed/crashed)
  SCAN_STATUS=$(python3 -c "
import json, sys
d = json.load(open('$TMPFILE'))
s = d.get('summary', {})
status = d.get('status') or s.get('status', '')
print(status)
" 2>/dev/null || echo "")

  if [ "$SCAN_STATUS" = "completed" ]; then
    echo "  PASS: scan status=completed"
  elif [ -n "$SCAN_STATUS" ]; then
    echo "  FAIL: scan status=${SCAN_STATUS} (expected completed)"
    ERRORS=$((ERRORS + 1))
  else
    echo "  WARN: no status field in results"
  fi

  # Verify smoke test flag and checks
  python3 -c "
import json, sys
d = json.load(open('$TMPFILE'))
s = d.get('summary', {})
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
  echo "  FAIL: No JSON results found for scan_uuid=${SCAN_UUID}"
  ERRORS=$((ERRORS + 1))
fi

# Summary
echo ""
echo "=== Cloud Function Smoke Test Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: All checks passed for ${ENV}"
  exit 0
else
  echo "FAIL: ${ERRORS} check(s) failed for ${ENV}"
  exit 1
fi
