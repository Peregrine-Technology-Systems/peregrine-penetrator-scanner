#!/usr/bin/env bash
# Stop VM (preserves disk and state)
set -euo pipefail
source "$(dirname "$0")/config.sh"

status=$(vm_status)
if [ -z "$status" ]; then
  log_error "VM '${VM_NAME}' does not exist"
  exit 1
fi

if [ "$status" = "TERMINATED" ] || [ "$status" = "STOPPED" ]; then
  log_ok "VM '${VM_NAME}' is already stopped"
  exit 0
fi

log_info "Stopping VM '${VM_NAME}'..."
gcloud compute instances stop "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}"

log_ok "VM stopped. Data disk preserved. Use './cloud/dev start' to resume."
