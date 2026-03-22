#!/usr/bin/env bash
# Scavenge orphaned scan VMs that failed to self-terminate
# Runs every 15 minutes via Cloud Scheduler or manually via ./cloud/dev scavenge
set -euo pipefail
source "$(dirname "$0")/config.sh"

MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-30}"

log_info "Scanning for orphaned scan VMs older than ${MAX_AGE_MINUTES} minutes..."

# List all pentest-scan-* VMs across all zones (never touch pentest-dev-vm)
VMS=$(gcloud compute instances list \
  --project="${GCP_PROJECT}" \
  --filter="name~^pentest-scan- AND status=RUNNING" \
  --format="json(name,zone.basename(),creationTimestamp)" 2>/dev/null || echo "[]")

ORPHAN_COUNT=0
NOW=$(date +%s)
MAX_AGE_SECONDS=$((MAX_AGE_MINUTES * 60))

echo "$VMS" | jq -c '.[]' 2>/dev/null | while read -r vm; do
  VM_NAME=$(echo "$vm" | jq -r '.name')
  VM_ZONE=$(echo "$vm" | jq -r '.zone')
  CREATED=$(echo "$vm" | jq -r '.creationTimestamp')
  CREATED_EPOCH=$(date -d "$CREATED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${CREATED%%.*}" +%s 2>/dev/null || echo "0")

  AGE_SECONDS=$((NOW - CREATED_EPOCH))
  AGE_MINUTES=$((AGE_SECONDS / 60))

  if [ "$AGE_SECONDS" -gt "$MAX_AGE_SECONDS" ]; then
    log_warn "Deleting orphaned VM: ${VM_NAME} (age: ${AGE_MINUTES}m, zone: ${VM_ZONE})"
    gcloud compute instances delete "${VM_NAME}" \
      --zone="${VM_ZONE}" \
      --project="${GCP_PROJECT}" \
      --quiet 2>/dev/null || log_error "Failed to delete ${VM_NAME}"
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    slack_notify ":wastebasket: Scavenged orphaned VM \`${VM_NAME}\` (ran for ${AGE_MINUTES}m)"
  else
    log_info "  ${VM_NAME}: ${AGE_MINUTES}m old — keeping"
  fi
done

if [ "$ORPHAN_COUNT" -eq 0 ]; then
  log_ok "No orphaned scan VMs found"
fi
