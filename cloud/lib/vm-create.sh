#!/usr/bin/env bash
# Create the dev VM and attach persistent data disk
set -euo pipefail
source "$(dirname "$0")/config.sh"

# Check if VM already exists
status=$(vm_status)
if [ -n "$status" ]; then
  log_warn "VM '${VM_NAME}' already exists (status: ${status})"
  if [ "$status" = "TERMINATED" ] || [ "$status" = "STOPPED" ]; then
    log_info "Use './cloud/dev start' to start it"
  fi
  exit 0
fi

# Ensure persistent data disk exists
if ! gcloud compute disks describe "${DATA_DISK_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT}" &>/dev/null; then
  log_info "Creating persistent data disk '${DATA_DISK_NAME}' (${DATA_DISK_SIZE})..."
  gcloud compute disks create "${DATA_DISK_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT}" \
    --size="${DATA_DISK_SIZE}" \
    --type="${DATA_DISK_TYPE}"
  log_ok "Data disk created"
else
  log_ok "Data disk '${DATA_DISK_NAME}' already exists"
fi

# Create VM
log_info "Creating VM '${VM_NAME}' (${VM_MACHINE_TYPE})..."
gcloud compute instances create "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --machine-type="${VM_MACHINE_TYPE}" \
  --image-family="${VM_IMAGE_FAMILY}" \
  --image-project="${VM_IMAGE_PROJECT}" \
  --boot-disk-size="${VM_BOOT_DISK_SIZE}" \
  --boot-disk-type=pd-standard \
  --disk="name=${DATA_DISK_NAME},device-name=pentest-data,mode=rw,boot=no,auto-delete=no" \
  --service-account="${VM_SERVICE_ACCOUNT}" \
  --scopes=cloud-platform \
  --metadata="SCAN_MODE=dev,SLACK_WEBHOOK_URL=$(grep '^SLACK_WEBHOOK_URL=' "${PROJECT_ROOT}/.env" 2>/dev/null | cut -d= -f2- || echo '')" \
  --tags=pentest-dev \
  --labels=env=dev,project=pentest

log_ok "VM created"

# Wait for SSH then run setup
wait_for_ssh

log_info "Running initial VM setup..."
gcloud compute scp \
  "${CLOUD_DIR}/lib/setup-vm.sh" \
  "${VM_NAME}:~/setup-vm.sh" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --strict-host-key-checking=no

vm_ssh "chmod +x ~/setup-vm.sh && sudo ~/setup-vm.sh"

log_ok "VM '${VM_NAME}' is ready"
log_info "Run './cloud/dev build' to sync code and build"
