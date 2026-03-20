#!/usr/bin/env bash
# Delete VM but keep the persistent data disk
set -euo pipefail
source "$(dirname "$0")/config.sh"

status=$(vm_status)
if [ -z "$status" ]; then
  log_warn "VM '${VM_NAME}' does not exist"
  exit 0
fi

log_warn "Deleting VM '${VM_NAME}' (data disk '${DATA_DISK_NAME}' will be preserved)..."
gcloud compute instances delete "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --quiet

log_ok "VM deleted. Data disk '${DATA_DISK_NAME}' preserved."
log_info "Use './cloud/dev start' to create a new VM with the same data disk."
