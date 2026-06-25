#!/usr/bin/env bash
set -euo pipefail

# Unified VM startup script for all environments (Packer-native model).
# Behavior determined by SCAN_MODE instance metadata: dev | development | staging | production
#
# dev:         Wait for SSH (interactive dev VM — no scan run)
# development: Clone development branch, run scan natively, upload results, self-terminate
# staging:     Clone staging branch, run scan natively, upload results, self-terminate
# production:  Clone main branch, run scan natively, upload results, self-terminate (SPOT)
#
# All scan environments: toolchain is pre-installed in the Packer image;
# no Docker required. (#903)

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
  curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/attributes/$1" 2>/dev/null || echo "${2:-}"
}

SCAN_MODE=$(get_metadata "SCAN_MODE" "dev")
PROJECT_ID=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/project/project-id")
ZONE=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/zone" | cut -d'/' -f4)
INSTANCE_NAME=$(curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/name")

# Write lifecycle status to GCS for observability (scavenger, smoke tests, humans)
write_status() {
  local phase="$1"
  local extra="${2:-}"
  local scan_uuid
  scan_uuid=$(get_metadata "SCAN_UUID" "")
  local gcs_bucket
  gcs_bucket=$(get_metadata "GCS_BUCKET" "${PROJECT_ID}-pentest-reports")
  [ -z "${scan_uuid}" ] && return 0
  local payload
  payload=$(cat <<STATUSEOF
{"scan_uuid":"${scan_uuid}","phase":"${phase}","instance_name":"${INSTANCE_NAME}","scan_mode":"${SCAN_MODE}","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"${extra}}
STATUSEOF
  )
  echo "${payload}" | gsutil cp - "gs://${gcs_bucket}/control/${scan_uuid}/status.json" 2>/dev/null || true
  echo "[lifecycle] ${phase}"
}

# Send Slack notification from VM (complements Ruby-level notifications)
send_slack() {
  local message="$1"
  local webhook_url
  webhook_url=$(get_metadata "SLACK_WEBHOOK_URL" "")
  [ -z "${webhook_url}" ] && return 0
  curl -sf -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"${message}\"}" \
    "${webhook_url}" 2>/dev/null || true
}

# Self-terminate on failure for scan VMs (prevents orphaned VMs incurring cost)
self_terminate() {
  write_status "terminating"
  send_slack ":skull: VM self-terminating: ${INSTANCE_NAME} (${SCAN_MODE})"
  echo "=== Self-terminating VM ${INSTANCE_NAME} ==="
  sleep 5
  if ! gcloud compute instances delete "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null; then
    echo "ERROR: gcloud delete failed for ${INSTANCE_NAME} — falling back to shutdown"
    send_slack ":warning: gcloud delete failed for ${INSTANCE_NAME} — shutting down (scavenger will clean up)"
    /sbin/shutdown -h now 2>/dev/null || true
  fi
}

if [ "$SCAN_MODE" != "dev" ]; then
  trap self_terminate EXIT
fi

echo "=== Pentest VM Startup (mode: ${SCAN_MODE}) ==="

# --- Mode-specific behavior ---
case "$SCAN_MODE" in
  dev)
    echo "=== Dev Mode ==="
    echo "Dev mode startup complete — waiting for SSH"
    ;;

  development|staging|production)
    echo "=== Scan Mode: ${SCAN_MODE} ==="

    # Read scan configuration from metadata
    SCAN_BRANCH=$(get_metadata "SCAN_BRANCH" "development")
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

    echo "Branch: ${SCAN_BRANCH}"
    echo "Profile: ${SCAN_PROFILE}"
    echo "Target: ${TARGET_URLS}"

    # Write tool versions to GCS at startup for smoke-test verification (#903)
    # This proves the Packer-baked toolchain is present and correct.
    NUCLEI_VER=$(nuclei -version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    RUBY_VER=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null || echo "unknown")
    NODE_VER=$(node --version 2>/dev/null | tr -d 'v' || echo "unknown")
    VERSIONS_JSON="{\"nuclei\":\"${NUCLEI_VER}\",\"ruby\":\"${RUBY_VER}\",\"node\":\"${NODE_VER}\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    echo "Tool versions: nuclei=${NUCLEI_VER} ruby=${RUBY_VER} node=${NODE_VER}"
    if [ -n "${SCAN_UUID}" ]; then
      echo "${VERSIONS_JSON}" | gsutil cp - "gs://${GCS_BUCKET}/control/${SCAN_UUID}/versions.json" 2>/dev/null || true
    fi

    write_status "scanning"

    # Pull secrets from Secret Manager
    fetch_secret() {
      gcloud secrets versions access latest --secret="$1" --project="${PROJECT_ID}" 2>/dev/null || echo ""
    }

    ANTHROPIC_API_KEY=$(fetch_secret "pentest-anthropic-api-key")
    NVD_API_KEY=$(fetch_secret "pentest-nvd-api-key")
    SMTP_USERNAME=$(fetch_secret "pentest-smtp-username")
    SMTP_PASSWORD=$(fetch_secret "pentest-smtp-password")
    SCAN_CALLBACK_SECRET=$(fetch_secret "pentest-scan-callback-secret")

    REPO_URL="https://github.com/Peregrine-Technology-Systems/peregrine-penetrator-scanner.git"
    APP_DIR="/opt/scanner"

    SCAN_LOG="/tmp/scan.log"
    RESULTS_DIR="/tmp/scan-results"
    mkdir -p "${RESULTS_DIR}"

    # Max scan duration — prevents hung scans from blocking self-termination
    SCAN_TIMEOUT="${SCAN_TIMEOUT:-3600}"  # 1 hour default

    echo "Cloning repo (branch: ${SCAN_BRANCH})..."
    git clone --depth 1 --branch "${SCAN_BRANCH}" "${REPO_URL}" "${APP_DIR}"

    echo "Installing gems..."
    cd "${APP_DIR}"
    bundle install --deployment --without development test --jobs 4 --quiet

    SCAN_EXIT=0

    echo "Running ${SCAN_PROFILE} scan (timeout: ${SCAN_TIMEOUT}s)..."
    # Redirect output to log file — GCE startup script runner crashes on long
    # stdout lines (bufio.Scanner buffer overflow), killing the EXIT trap and
    # orphaning the VM. See scanner#631.
    timeout --signal=TERM --kill-after=60 "${SCAN_TIMEOUT}" \
      env \
        SCAN_PROFILE="${SCAN_PROFILE}" \
        SCAN_MODE="${SCAN_MODE}" \
        APP_ENV=production \
        TARGET_NAME="${TARGET_NAME}" \
        TARGET_URLS="${TARGET_URLS}" \
        NVD_API_KEY="${NVD_API_KEY}" \
        SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" \
        GCS_BUCKET="${GCS_BUCKET}" \
        GOOGLE_CLOUD_PROJECT="${PROJECT_ID}" \
        VERSION="${VERSION}" \
        VM_MACHINE_TYPE="${MACHINE_TYPE}" \
        SPOT_INSTANCE="${SPOT_INSTANCE}" \
        SCAN_UUID="${SCAN_UUID}" \
        CALLBACK_URL="${CALLBACK_URL}" \
        SCAN_CALLBACK_SECRET="${SCAN_CALLBACK_SECRET}" \
        JOB_ID="${JOB_ID}" \
        REPORTER_BASE_URL="${REPORTER_BASE_URL}" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        SMTP_HOST="${SMTP_HOST}" \
        SMTP_PORT="${SMTP_PORT}" \
        SMTP_USERNAME="${SMTP_USERNAME}" \
        SMTP_PASSWORD="${SMTP_PASSWORD}" \
        NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL}" \
      bundle exec bin/scan \
      > "${SCAN_LOG}" 2>&1 || SCAN_EXIT=$?

    echo "--- Scan Log (last 20 lines) ---"
    tail -20 "${SCAN_LOG}" 2>/dev/null || true

    if [ "$SCAN_EXIT" -eq 0 ]; then
      echo "Scan completed successfully"
      write_status "completed" ",\"scan_exit_code\":0"
      send_slack ":white_check_mark: Scan completed: ${TARGET_NAME} (${SCAN_PROFILE}) — uploading results"
    elif [ "$SCAN_EXIT" -eq 124 ]; then
      echo "ERROR: Scan timed out after ${SCAN_TIMEOUT}s"
      write_status "failed" ",\"scan_exit_code\":124,\"error\":\"timeout after ${SCAN_TIMEOUT}s\""
      send_slack ":warning: Scan timed out: ${TARGET_NAME} (${SCAN_PROFILE}) after ${SCAN_TIMEOUT}s"
    else
      echo "Scan failed with exit code ${SCAN_EXIT}"
      write_status "failed" ",\"scan_exit_code\":${SCAN_EXIT}"
      send_slack ":x: Scan failed: ${TARGET_NAME} (${SCAN_PROFILE}) exit code ${SCAN_EXIT}"
    fi

    # Always upload the scan log to GCS for post-mortem — the serial console is
    # unreliable for long output (#631) and the VM self-destructs, so a failed
    # scan otherwise leaves no trace. (#784)
    if [ -f "${SCAN_LOG}" ]; then
      timeout 60 gsutil cp "${SCAN_LOG}" "gs://${GCS_BUCKET}/vm-results/${INSTANCE_NAME}/scan.log" 2>/dev/null \
        && echo "Scan log → gs://${GCS_BUCKET}/vm-results/${INSTANCE_NAME}/scan.log" \
        || echo "WARNING: scan log upload to GCS failed"
    fi

    # Upload results to GCS (backup — scanner also uploads via StorageService)
    # Timeout prevents hung uploads from blocking self-termination (#650)
    if [ -n "$(ls -A ${RESULTS_DIR} 2>/dev/null)" ]; then
      write_status "uploading"
      echo "Uploading results to gs://${GCS_BUCKET}/..."
      if timeout 120 gsutil -m cp -r "${RESULTS_DIR}/*" "gs://${GCS_BUCKET}/vm-results/${INSTANCE_NAME}/" 2>/dev/null; then
        write_status "uploaded"
      else
        write_status "upload_failed"
        send_slack ":warning: GCS upload failed or timed out: ${TARGET_NAME} — results may be lost"
      fi
    fi

    # Self-termination handled by EXIT trap
    ;;

  *)
    echo "Unknown SCAN_MODE: ${SCAN_MODE}"
    exit 1
    ;;
esac
