#!/usr/bin/env bash
# Cloud development environment configuration
# All GCP resource names and settings in one place

set -euo pipefail

# GCP Project
export GCP_PROJECT="${GCP_PROJECT:-peregrine-pentest-dev}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export GCP_ZONE="${GCP_ZONE:-us-central1-a}"

# VM Configuration
export VM_NAME="${VM_NAME:-pentest-dev-vm}"
export VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-e2-standard-4}"
export VM_IMAGE_FAMILY="ubuntu-2204-lts"
export VM_IMAGE_PROJECT="ubuntu-os-cloud"
export VM_BOOT_DISK_SIZE="30GB"
export VM_SERVICE_ACCOUNT="pentest-scanner@${GCP_PROJECT}.iam.gserviceaccount.com"

# Persistent Data Disk
export DATA_DISK_NAME="${DATA_DISK_NAME:-pentest-data}"
export DATA_DISK_SIZE="${DATA_DISK_SIZE:-200GB}"
export DATA_DISK_TYPE="pd-standard"
export DATA_MOUNT_POINT="/mnt/pentest-data"

# Docker / Registry
export REGISTRY="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/pentest"
export IMAGE_NAME="scanner"
export IMAGE_TAG="${IMAGE_TAG:-latest}"
export FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

# Paths
export CLOUD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$(cd "${CLOUD_DIR}/.." && pwd)"
export LOCAL_RESULTS_DIR="${PROJECT_ROOT}/tmp/cloud-results"

# Remote paths
export REMOTE_PROJECT_DIR="/home/\$(whoami)/pentest-platform"
export REMOTE_SCAN_RESULTS="${DATA_MOUNT_POINT}/scan-results"
export REMOTE_DOCKER_DATA="${DATA_MOUNT_POINT}/docker"
export REMOTE_BUILDKIT_CACHE="${DATA_MOUNT_POINT}/buildkit-cache"

# Auto-idle settings
export IDLE_CHECK_INTERVAL_MIN=5
export IDLE_SHUTDOWN_THRESHOLD_MIN=10
export MAX_VM_RUNTIME_HOURS=4

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[info]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
log_error() { echo -e "${RED}[error]${NC} $*" >&2; }

# Helper: send Slack notification
slack_notify() {
  local message="$1"
  local webhook_url="${SLACK_WEBHOOK_URL:-}"
  [ -z "$webhook_url" ] && [ -f "${PROJECT_ROOT}/.env" ] && \
    webhook_url=$(grep "^SLACK_WEBHOOK_URL=" "${PROJECT_ROOT}/.env" 2>/dev/null | cut -d= -f2- || echo "")
  [ -z "$webhook_url" ] && return 0
  curl -sf -X POST -H 'Content-type: application/json' \
    --data "{\"text\": \"${message}\"}" \
    "$webhook_url" > /dev/null 2>&1 || true
}

# Helper: run gcloud compute ssh command on VM
vm_ssh() {
  gcloud compute ssh "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT}" \
    --strict-host-key-checking=no \
    --command="$1" \
    2>/dev/null
}

# Helper: run gcloud compute scp
vm_scp() {
  # $1 = source, $2 = dest
  gcloud compute scp "$1" "$2" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT}" \
    --strict-host-key-checking=no
}

# Helper: get VM status (RUNNING, TERMINATED, STOPPED, or empty if not exists)
vm_status() {
  gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT}" \
    --format="value(status)" 2>/dev/null || echo ""
}

# Helper: wait for VM to be SSH-ready
wait_for_ssh() {
  local max_attempts="${1:-30}"
  local attempt=0
  log_info "Waiting for SSH access..."
  while [ $attempt -lt $max_attempts ]; do
    if gcloud compute ssh "${VM_NAME}" \
        --zone="${GCP_ZONE}" \
        --project="${GCP_PROJECT}" \
        --strict-host-key-checking=no \
        --command="echo ready" \
        &>/dev/null; then
      log_ok "SSH ready"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
  log_error "SSH not ready after $((max_attempts * 5)) seconds"
  return 1
}
