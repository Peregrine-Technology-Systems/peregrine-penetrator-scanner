#!/usr/bin/env bash
set -euo pipefail

# Unified VM startup script for all environments
# Behavior determined by SCAN_MODE instance metadata: dev | staging | production
#
# dev:        Mount data disk, start Docker, install idle-shutdown, wait for SSH
# staging:    Pull image, run scan, upload results to GCS, self-terminate
# production: Same as staging but with spot pricing

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/attributes/$1" 2>/dev/null || echo "${2:-}"
}

SCAN_MODE=$(get_metadata "SCAN_MODE" "dev")
PROJECT_ID=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/project/project-id")
ZONE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/zone" | cut -d'/' -f4)
INSTANCE_NAME=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/name")

# Self-terminate on failure for scan VMs (prevents orphaned VMs incurring cost)
self_terminate() {
  echo "=== Self-terminating VM ${INSTANCE_NAME} ==="
  sleep 5
  if ! gcloud compute instances delete "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --quiet 2>&1; then
    echo "ERROR: Self-terminate failed for ${INSTANCE_NAME} — scavenger will clean up"
  fi
}

if [ "$SCAN_MODE" != "dev" ]; then
  trap self_terminate EXIT
fi

echo "=== Pentest VM Startup (mode: ${SCAN_MODE}) ==="

# --- Common: Install Docker if missing ---
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi

# --- Common: Configure Artifact Registry auth ---
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet 2>/dev/null || true

# --- Mode-specific behavior ---
case "$SCAN_MODE" in
  dev)
    echo "=== Dev Mode ==="
    # Mount persistent data disk, configure Docker data-root, install idle-shutdown
    # This is handled by setup-vm.sh (called from vm-create.sh)
    echo "Dev mode startup complete — waiting for SSH"
    ;;

  staging|production)
    echo "=== Scan Mode: ${SCAN_MODE} ==="

    # Read scan configuration from metadata
    REGISTRY=$(get_metadata "REGISTRY" "us-central1-docker.pkg.dev/${PROJECT_ID}/pentest")
    IMAGE_TAG=$(get_metadata "IMAGE_TAG" "latest")
    SCAN_PROFILE=$(get_metadata "SCAN_PROFILE" "standard")
    TARGET_URLS=$(get_metadata "TARGET_URLS" "")
    GCS_BUCKET=$(get_metadata "GCS_BUCKET" "${PROJECT_ID}-pentest-reports")
    SLACK_WEBHOOK_URL=$(get_metadata "SLACK_WEBHOOK_URL" "")
    NOTIFICATION_EMAIL=$(get_metadata "NOTIFICATION_EMAIL" "")
    SMTP_HOST=$(get_metadata "SMTP_HOST" "mail.authsmtp.com")
    SMTP_PORT=$(get_metadata "SMTP_PORT" "2525")
    VERSION=$(get_metadata "VERSION" "")
    SCAN_UUID=$(get_metadata "SCAN_UUID" "")
    CALLBACK_URL=$(get_metadata "CALLBACK_URL" "")

    # Read machine type from instance metadata for cost tracking
    MACHINE_TYPE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/machine-type" 2>/dev/null | rev | cut -d'/' -f1 | rev || echo "unknown")
    SPOT_INSTANCE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/scheduling/preemptible" 2>/dev/null || echo "false")

    FULL_IMAGE="${REGISTRY}/scanner:${IMAGE_TAG}"

    echo "Image: ${FULL_IMAGE}"
    echo "Profile: ${SCAN_PROFILE}"
    echo "Target: ${TARGET_URLS}"

    # Pull secrets from Secret Manager
    fetch_secret() {
      gcloud secrets versions access latest --secret="$1" --project="${PROJECT_ID}" 2>/dev/null || echo ""
    }

    ANTHROPIC_API_KEY=$(fetch_secret "pentest-anthropic-api-key")
    NVD_API_KEY=$(fetch_secret "pentest-nvd-api-key")
    SMTP_USERNAME=$(fetch_secret "pentest-smtp-username")
    SMTP_PASSWORD=$(fetch_secret "pentest-smtp-password")
    SCAN_CALLBACK_SECRET=$(fetch_secret "pentest-scan-callback-secret")

    # Pull image
    echo "Pulling image..."
    docker pull "${FULL_IMAGE}"

    # Create results directory
    RESULTS_DIR="/tmp/scan-results"
    mkdir -p "${RESULTS_DIR}"

    # Run scan
    echo "Running ${SCAN_PROFILE} scan..."
    SCAN_EXIT=0
    docker run --rm \
      -e SCAN_PROFILE="${SCAN_PROFILE}" \
      -e "SCAN_MODE=${SCAN_MODE}" \
      -e RAILS_ENV=production \
      -e "TARGET_URLS=${TARGET_URLS}" \
      -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
      -e "NVD_API_KEY=${NVD_API_KEY}" \
      -e "SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}" \
      -e "NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL}" \
      -e "SMTP_HOST=${SMTP_HOST}" \
      -e "SMTP_PORT=${SMTP_PORT}" \
      -e "SMTP_USERNAME=${SMTP_USERNAME}" \
      -e "SMTP_PASSWORD=${SMTP_PASSWORD}" \
      -e "GCS_BUCKET=${GCS_BUCKET}" \
      -e "GOOGLE_CLOUD_PROJECT=${PROJECT_ID}" \
      -e "VERSION=${VERSION}" \
      -e "VM_MACHINE_TYPE=${MACHINE_TYPE}" \
      -e "SPOT_INSTANCE=${SPOT_INSTANCE}" \
      -e "SCAN_UUID=${SCAN_UUID}" \
      -e "CALLBACK_URL=${CALLBACK_URL}" \
      -e "SCAN_CALLBACK_SECRET=${SCAN_CALLBACK_SECRET}" \
      -v "${RESULTS_DIR}:/app/storage/reports" \
      --name "pentest-scan-$(date +%Y%m%d-%H%M%S)" \
      "${FULL_IMAGE}" \
      rake scan:run || SCAN_EXIT=$?

    if [ "$SCAN_EXIT" -eq 0 ]; then
      echo "Scan completed successfully"
    else
      echo "Scan failed with exit code ${SCAN_EXIT}"
    fi

    # Upload results to GCS (backup — scanner also uploads via StorageService)
    if [ -n "$(ls -A ${RESULTS_DIR} 2>/dev/null)" ]; then
      echo "Uploading results to gs://${GCS_BUCKET}/..."
      gsutil -m cp -r "${RESULTS_DIR}/*" "gs://${GCS_BUCKET}/vm-results/${INSTANCE_NAME}/" 2>/dev/null || true
    fi

    # Self-termination handled by EXIT trap
    ;;

  *)
    echo "Unknown SCAN_MODE: ${SCAN_MODE}"
    exit 1
    ;;
esac
