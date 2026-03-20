#!/usr/bin/env bash
# Download scan results from VM to local machine
set -euo pipefail
source "$(dirname "$0")/config.sh"

# Ensure VM is running
status=$(vm_status)
if [ "$status" != "RUNNING" ]; then
  log_error "VM is not running (status: ${status:-not found})"
  log_info "Run './cloud/dev start' first"
  exit 1
fi

# Create local results directory
mkdir -p "${LOCAL_RESULTS_DIR}"

# Find latest results on VM
LATEST=$(vm_ssh "ls -t ${DATA_MOUNT_POINT}/scan-results/ 2>/dev/null | head -1" || echo "")

if [ -z "$LATEST" ]; then
  log_warn "No scan results found on VM"
  exit 0
fi

log_info "Downloading results from ${DATA_MOUNT_POINT}/scan-results/..."

# Download all results
gcloud compute scp --recurse \
  "${VM_NAME}:${DATA_MOUNT_POINT}/scan-results/" \
  "${LOCAL_RESULTS_DIR}/" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --strict-host-key-checking=no

log_ok "Results downloaded to ${LOCAL_RESULTS_DIR}/"

# List what we got
echo ""
log_info "Downloaded files:"
find "${LOCAL_RESULTS_DIR}" -type f | head -20 | while read -r f; do
  echo "  $(basename "$f") ($(du -h "$f" | cut -f1))"
done

RESULT_COUNT=$(find "${LOCAL_RESULTS_DIR}" -type f | wc -l | tr -d ' ')
log_ok "${RESULT_COUNT} files in ${LOCAL_RESULTS_DIR}/"
