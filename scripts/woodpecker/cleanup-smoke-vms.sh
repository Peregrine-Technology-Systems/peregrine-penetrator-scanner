#!/usr/bin/env bash
set -euo pipefail

# Delete stale smoke test VMs older than MAX_AGE_MINUTES
# Runs after every smoke test (success or failure) to prevent orphaned VMs

BRANCH="${CI_COMMIT_BRANCH:-staging}"
GCP_PROJECT="${GCP_PROJECT_DEV:?GCP_PROJECT_DEV not set}"
MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-10}"

VM_PREFIX="pentest-scan-${BRANCH}-"
echo "=== Cleanup: stale smoke test VMs (prefix: ${VM_PREFIX}, max age: ${MAX_AGE_MINUTES}m) ==="

CUTOFF=$(date -u -d "-${MAX_AGE_MINUTES} minutes" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
  || date -u -v-${MAX_AGE_MINUTES}M +%Y-%m-%dT%H:%M:%S)

VMS=$(gcloud compute instances list \
  --filter="name~${VM_PREFIX} AND creationTimestamp<${CUTOFF}" \
  --project="${GCP_PROJECT}" \
  --format="value(name,zone)" 2>/dev/null || echo "")

if [ -z "$VMS" ]; then
  echo "No stale VMs found."
  exit 0
fi

DELETED=0
while IFS=$'\t' read -r NAME ZONE; do
  echo "Deleting stale VM: ${NAME} (zone: ${ZONE})"
  gcloud compute instances delete "$NAME" \
    --project="${GCP_PROJECT}" --zone="${ZONE}" --quiet 2>&1 || true
  DELETED=$((DELETED + 1))
done <<< "$VMS"

echo "Cleaned up ${DELETED} stale VM(s)."
