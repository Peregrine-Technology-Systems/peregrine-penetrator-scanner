#!/usr/bin/env bash
set -euo pipefail

# Launch an ephemeral scan VM on GCP using the Packer-baked scanner-base image.
# Usage: trigger-scan.sh <development|staging|production> <profile>
#
# All environments clone the appropriate git branch at boot and run natively
# (no Docker pull). The Packer image provides the toolchain; git provides the code.
#   development → clone development branch
#   staging     → clone staging branch
#   production  → clone main branch

ENV="${1:?Usage: trigger-scan.sh <development|staging|production> <profile>}"
PROFILE="${2:-standard}"

GCP_PROJECT="${GCP_PROJECT:-peregrine-pentest-dev}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
VM_NAME="pentest-scan-${ENV}-$(date +%Y%m%d-%H%M%S)"
SCAN_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null \
  || uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
  || echo "scan-$(date +%s)")

case "$ENV" in
  development)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="AuxScan Production"
    SCAN_BRANCH="development"
    SPOT_FLAG=""
    ;;
  staging)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="AuxScan Production"
    SCAN_BRANCH="staging"
    SPOT_FLAG=""
    ;;
  production)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="AuxScan Production"
    SCAN_BRANCH="main"
    SPOT_FLAG="--provisioning-model=SPOT --instance-termination-action=DELETE"
    ;;
  *)
    echo "Unknown environment: ${ENV}" >&2
    exit 1
    ;;
esac

SLACK_URL="${SLACK_WEBHOOK_URL:-}"
EMAIL="${NOTIFICATION_EMAIL:-}"

# Resolve Packer-baked scanner-base image from Secret Manager pointer
# Falls back to image family query if SM is unavailable
echo "Resolving scanner-base image..." >&2
PACKER_IMAGE=$(gcloud secrets versions access latest \
  --secret=scanner-base--vm-base-image \
  --project=ci-runners-de 2>/dev/null || true)

if [ -z "${PACKER_IMAGE}" ]; then
  echo "SM pointer unavailable, querying image family..." >&2
  PACKER_IMAGE=$(gcloud compute images describe-from-family scanner-base \
    --project="${GCP_PROJECT}" \
    --format="value(name)" 2>/dev/null || true)
fi

if [ -z "${PACKER_IMAGE}" ]; then
  echo "ERROR: Could not resolve scanner-base image from SM or image family" >&2
  exit 1
fi

echo "Launching ${ENV} scan VM: ${VM_NAME}" >&2
echo "  Image: ${PACKER_IMAGE} (${GCP_PROJECT})" >&2
echo "  Branch: ${SCAN_BRANCH}" >&2
echo "  Profile: ${PROFILE}" >&2
echo "  Target: ${TARGET_URLS}" >&2
echo "  SCAN_UUID: ${SCAN_UUID}" >&2

STARTUP_SCRIPT="${CI_WORKSPACE}/cloud/lib/vm-startup.sh"

gcloud compute instances create "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --machine-type=e2-standard-4 \
  --image="${PACKER_IMAGE}" \
  --image-project="${GCP_PROJECT}" \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-standard \
  --boot-disk-auto-delete \
  --service-account="pentest-scanner@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --scopes=cloud-platform \
  --metadata="SCAN_MODE=${ENV},SCAN_BRANCH=${SCAN_BRANCH},SCAN_PROFILE=${PROFILE},TARGET_NAME=${TARGET_NAME},TARGET_URLS=${TARGET_URLS},GCS_BUCKET=${GCP_PROJECT}-pentest-reports,SLACK_WEBHOOK_URL=${SLACK_URL},NOTIFICATION_EMAIL=${EMAIL},SCAN_UUID=${SCAN_UUID}" \
  --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
  --tags=pentest-scan \
  --labels="env=${ENV},project=pentest,scan=true" \
  ${SPOT_FLAG} \
  --quiet >&2

echo "Scan VM '${VM_NAME}' launched — will self-terminate after scan" >&2

# Emit SCAN_UUID to stdout for callers that need to track this scan
echo "${SCAN_UUID}"
