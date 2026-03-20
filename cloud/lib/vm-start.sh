#!/usr/bin/env bash
# Start a stopped VM
set -euo pipefail
source "$(dirname "$0")/config.sh"

status=$(vm_status)

if [ -z "$status" ]; then
  log_info "VM does not exist. Creating..."
  exec "$(dirname "$0")/vm-create.sh"
fi

if [ "$status" = "RUNNING" ]; then
  log_ok "VM '${VM_NAME}' is already running"
  exit 0
fi

if [ "$status" = "STAGING" ]; then
  log_info "VM '${VM_NAME}' is starting up..."
  wait_for_ssh
  log_ok "VM ready"
  exit 0
fi

log_info "Starting VM '${VM_NAME}'..."
gcloud compute instances start "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}"

wait_for_ssh
log_ok "VM '${VM_NAME}' is running"
