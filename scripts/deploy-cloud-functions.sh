#!/usr/bin/env bash
set -euo pipefail

# Deploy Cloud Functions from cloud/scheduler/ and verify health endpoints.
#
# Usage:
#   scripts/deploy-cloud-functions.sh                # Deploy all functions
#   scripts/deploy-cloud-functions.sh --function vm-scavenger  # Deploy one
#
# Requires: gcloud auth with Cloud Functions Admin role

GCP_PROJECT="${GCP_PROJECT:?GCP_PROJECT not set}"
REGION="${GCP_REGION:-us-central1}"
SOURCE_DIR="cloud/scheduler"
FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --function) FILTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# name:entry_point:memory
FUNCTIONS=(
  "vm-scavenger:scavenge_vms:512Mi"
  "trigger-scan-development:trigger_development:256Mi"
  "trigger-scan-staging:trigger_staging:256Mi"
  "trigger-scan-production:trigger_production:256Mi"
)

DEPLOYED=0
FAILURES=0

echo "=== Deploying Cloud Functions ==="
echo "Project: ${GCP_PROJECT}, Region: ${REGION}"
echo ""

for fn_spec in "${FUNCTIONS[@]}"; do
  IFS=: read -r name entry_point memory <<< "$fn_spec"

  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  echo "==> Deploying ${name} (entry: ${entry_point}, mem: ${memory})"
  if gcloud functions deploy "$name" \
    --gen2 --region="$REGION" --project="$GCP_PROJECT" \
    --runtime=python312 --entry-point="$entry_point" \
    --trigger-http --allow-unauthenticated \
    --source="$SOURCE_DIR" \
    --memory="$memory" --timeout=300s \
    --set-env-vars="GCP_PROJECT=$GCP_PROJECT,GCP_REGION=$REGION" \
    --quiet; then
    DEPLOYED=$((DEPLOYED + 1))
    echo "  Deployed successfully"
  else
    echo "  FAIL: deploy failed for ${name}"
    FAILURES=$((FAILURES + 1))
  fi
  echo ""
done

if [ "$DEPLOYED" -eq 0 ]; then
  echo "No functions deployed"
  [ -n "$FILTER" ] && echo "(filter: ${FILTER} — check function name)"
  exit 1
fi

# Post-deploy health verification
echo "==> Verifying health endpoints..."
HEALTH_FAILURES=0

for fn_spec in "${FUNCTIONS[@]}"; do
  IFS=: read -r name _ _ <<< "$fn_spec"

  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  URL=$(gcloud functions describe "$name" \
    --region="$REGION" --project="$GCP_PROJECT" \
    --format='value(serviceConfig.uri)' 2>/dev/null || echo "")

  if [ -z "$URL" ]; then
    echo "  FAIL: could not get URL for ${name}"
    HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    continue
  fi

  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    -X GET "${URL}/health" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "  PASS: ${name} → 200"
  else
    echo "  FAIL: ${name} → ${HTTP_CODE}"
    HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
  fi
done

echo ""
echo "=== Deploy Summary ==="
echo "Deployed: ${DEPLOYED}, Deploy failures: ${FAILURES}, Health failures: ${HEALTH_FAILURES}"

TOTAL_FAILURES=$((FAILURES + HEALTH_FAILURES))
if [ "$TOTAL_FAILURES" -gt 0 ]; then
  echo "FAIL: ${TOTAL_FAILURES} total failure(s)"
  exit 1
fi

echo "All functions deployed and verified."
