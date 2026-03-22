#!/usr/bin/env bash
# SSH into the dev VM
set -euo pipefail
source "$(dirname "$0")/config.sh"

status=$(vm_status)
if [ "$status" != "RUNNING" ]; then
  log_error "VM is not running (status: ${status:-not found})"
  log_info "Run './cloud/dev start' first"
  exit 1
fi

exec gcloud compute ssh "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --strict-host-key-checking=no
