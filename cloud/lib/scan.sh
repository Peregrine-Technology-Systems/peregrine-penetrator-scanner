#!/usr/bin/env bash
# Run a scan on the VM, streaming output back
set -euo pipefail
source "$(dirname "$0")/config.sh"

PROFILE="${1:-standard}"

# Validate profile
if [[ ! "$PROFILE" =~ ^(quick|standard|thorough)$ ]]; then
  log_error "Invalid profile: ${PROFILE}"
  log_info "Valid profiles: quick, standard, thorough"
  exit 1
fi

# Ensure VM is running
status=$(vm_status)
if [ "$status" != "RUNNING" ]; then
  log_error "VM is not running (status: ${status:-not found})"
  log_info "Run './cloud/dev start' first"
  exit 1
fi

# Check image exists
if ! vm_ssh "docker image inspect ${FULL_IMAGE} &>/dev/null"; then
  log_error "Image '${FULL_IMAGE}' not found on VM"
  log_info "Run './cloud/dev build' first"
  exit 1
fi

# Load .env from local if it exists, pass as docker env vars
ENV_ARGS=""
if [ -f "${PROJECT_ROOT}/.env" ]; then
  log_info "Loading environment from local .env"
  ENV_ARGS="--env-file /tmp/pentest-scan.env"
  vm_scp "${PROJECT_ROOT}/.env" "${VM_NAME}:/tmp/pentest-scan.env"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

log_info "Running ${PROFILE} scan (results: ${DATA_MOUNT_POINT}/scan-results/)..."
log_info "Streaming output..."
echo "---"

# Run scan container with persistent results volume
vm_ssh "docker run --rm \
  ${ENV_ARGS} \
  -e SCAN_PROFILE=${PROFILE} \
  -e RAILS_ENV=production \
  -v ${DATA_MOUNT_POINT}/scan-results:/app/storage/reports \
  --name pentest-scan-${TIMESTAMP} \
  ${FULL_IMAGE} \
  rake scan:run"

echo "---"
log_ok "Scan complete"
log_info "Run './cloud/dev results' to download reports"
