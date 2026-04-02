#!/usr/bin/env bash
set -euo pipefail

# Unified VM startup script for all environments
# Behavior determined by SCAN_MODE instance metadata: dev | development | staging | production
#
# dev:         Mount data disk, start Docker, install idle-shutdown, wait for SSH
# development: Pull image, run scan, upload results to GCS, self-terminate (smoke test)
# staging:     Pull image, run scan, upload results to GCS, self-terminate
# production:  Same as staging but with spot pricing

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

  development|staging|production)
    echo "=== Scan Mode: ${SCAN_MODE} ==="

    # Read scan configuration from metadata
    REGISTRY=$(get_metadata "REGISTRY" "us-central1-docker.pkg.dev/${PROJECT_ID}/pentest")
    IMAGE_TAG=$(get_metadata "IMAGE_TAG" "latest")
    SCAN_PROFILE=$(get_metadata "SCAN_PROFILE" "standard")
    TARGET_URLS=$(get_metadata "TARGET_URLS" "")
    TARGET_NAME=$(get_metadata "TARGET_NAME" "")
    GCS_BUCKET=$(get_metadata "GCS_BUCKET" "${PROJECT_ID}-pentest-reports")
    SLACK_WEBHOOK_URL=$(get_metadata "SLACK_WEBHOOK_URL" "")
    NOTIFICATION_EMAIL=$(get_metadata "NOTIFICATION_EMAIL" "")
    SMTP_HOST=$(get_metadata "SMTP_HOST" "mail.authsmtp.com")
    SMTP_PORT=$(get_metadata "SMTP_PORT" "2525")
    VERSION=$(get_metadata "VERSION" "")
    SCAN_UUID=$(get_metadata "SCAN_UUID" "")
    CALLBACK_URL=$(get_metadata "CALLBACK_URL" "")
    JOB_ID=$(get_metadata "JOB_ID" "")
    REPORTER_BASE_URL=$(get_metadata "REPORTER_BASE_URL" "")

    # Read machine type from instance metadata for cost tracking
    MACHINE_TYPE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/machine-type" 2>/dev/null | rev | cut -d'/' -f1 | rev || echo "unknown")
    SPOT_INSTANCE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/scheduling/preemptible" 2>/dev/null || echo "false")

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

    # Common env vars for docker run
    SCAN_ENV=(
      -e SCAN_PROFILE="${SCAN_PROFILE}"
      -e "SCAN_MODE=${SCAN_MODE}"
      -e APP_ENV=production
      -e "TARGET_NAME=${TARGET_NAME}"
      -e "TARGET_URLS=${TARGET_URLS}"
      -e "NVD_API_KEY=${NVD_API_KEY}"
      -e "SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}"
      -e "GCS_BUCKET=${GCS_BUCKET}"
      -e "GOOGLE_CLOUD_PROJECT=${PROJECT_ID}"
      -e "VERSION=${VERSION}"
      -e "VM_MACHINE_TYPE=${MACHINE_TYPE}"
      -e "SPOT_INSTANCE=${SPOT_INSTANCE}"
      -e "SCAN_UUID=${SCAN_UUID}"
      -e "CALLBACK_URL=${CALLBACK_URL}"
      -e "SCAN_CALLBACK_SECRET=${SCAN_CALLBACK_SECRET}"
      -e "JOB_ID=${JOB_ID}"
      -e "REPORTER_BASE_URL=${REPORTER_BASE_URL}"
    )

    RESULTS_DIR="/tmp/scan-results"
    mkdir -p "${RESULTS_DIR}"

    # Max scan duration — prevents hung scans from blocking self-termination
    SCAN_TIMEOUT="${SCAN_TIMEOUT:-3600}"  # 1 hour default

    SCAN_EXIT=0

    # Dual-mode execution:
    #   development = clone code + volume mount into base image (fast iteration)
    #   staging/production = pull baked image (immutable, tested)
    if [ "${IMAGE_TAG}" = "development" ]; then
      # --- Clone mode: git clone + bundle install at boot ---
      BASE_IMAGE="${REGISTRY}/scanner-base:latest"
      REPO_URL="https://github.com/Peregrine-Technology-Systems/peregrine-penetrator-scanner.git"

      echo "Mode: clone (development)"
      echo "Base image: ${BASE_IMAGE}"

      docker pull "${BASE_IMAGE}"

      APP_DIR="/tmp/scanner-app"
      echo "Cloning repo (branch: development)..."
      git clone --depth 1 --branch development "${REPO_URL}" "${APP_DIR}"

      echo "Running ${SCAN_PROFILE} scan (timeout: ${SCAN_TIMEOUT}s)..."
      timeout --signal=TERM --kill-after=60 "${SCAN_TIMEOUT}" \
        docker run --rm \
          "${SCAN_ENV[@]}" \
          -v "${APP_DIR}:/app" \
          -v "${RESULTS_DIR}:/app/storage/reports" \
          --name "pentest-scan-$(date +%Y%m%d-%H%M%S)" \
          "${BASE_IMAGE}" \
          bash -c "cd /app && bundle install --deployment --without development test --jobs 4 --quiet && bundle exec bin/scan" \
          || SCAN_EXIT=$?
    else
      # --- Image mode: pull baked image (staging or production) ---
      FULL_IMAGE="${REGISTRY}/scanner:${IMAGE_TAG}"

      echo "Mode: baked image (${IMAGE_TAG})"
      echo "Image: ${FULL_IMAGE}"

      docker pull "${FULL_IMAGE}"

      echo "Running ${SCAN_PROFILE} scan (timeout: ${SCAN_TIMEOUT}s)..."
      timeout --signal=TERM --kill-after=60 "${SCAN_TIMEOUT}" \
        docker run --rm \
          "${SCAN_ENV[@]}" \
          -v "${RESULTS_DIR}:/app/storage/reports" \
          --name "pentest-scan-$(date +%Y%m%d-%H%M%S)" \
          "${FULL_IMAGE}" \
          bundle exec bin/scan \
          || SCAN_EXIT=$?
    fi

    if [ "$SCAN_EXIT" -eq 0 ]; then
      echo "Scan completed successfully"
    elif [ "$SCAN_EXIT" -eq 124 ]; then
      echo "ERROR: Scan timed out after ${SCAN_TIMEOUT}s — docker run killed"
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
