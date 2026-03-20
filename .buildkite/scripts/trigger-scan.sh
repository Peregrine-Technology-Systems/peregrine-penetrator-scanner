#!/usr/bin/env bash
set -euo pipefail

# Launch an ephemeral scan VM from Buildkite
# Usage: trigger-scan.sh <staging|production> <profile> <image_tag>

ENV="${1:?Usage: trigger-scan.sh <staging|production> <profile> <image_tag>}"
PROFILE="${2:-standard}"
IMAGE_TAG="${3:-${ENV}}"

GCP_PROJECT="${GCP_PROJECT:-peregrine-pentest-dev}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
REGISTRY="${DOCKER_REGISTRY:-us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest}"
VM_NAME="pentest-scan-${ENV}-$(date +%Y%m%d-%H%M%S)"

case "$ENV" in
  staging)
    TARGET_URLS='["https://auxscan.stage.data-estate.cloud"]'
    SPOT_FLAG=""
    ;;
  production)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    SPOT_FLAG="--provisioning-model=SPOT --instance-termination-action=DELETE"
    ;;
  *)
    echo "Unknown environment: ${ENV}"
    exit 1
    ;;
esac

# Fetch secrets for scan notifications
SLACK_WEBHOOK_URL=$(gcloud secrets versions access latest \
  --secret="web-app-penetration-test--slack-webhook-url" \
  --project=ci-runners-de 2>/dev/null || echo "")
NOTIFICATION_EMAIL=$(gcloud secrets versions access latest \
  --secret="web-app-penetration-test--notification-email" \
  --project=ci-runners-de 2>/dev/null || echo "")

echo "Launching ${ENV} scan VM: ${VM_NAME}"
echo "  Image: ${REGISTRY}/scanner:${IMAGE_TAG}"
echo "  Profile: ${PROFILE}"
echo "  Target: ${TARGET_URLS}"

# Get the startup script path (relative to repo root)
STARTUP_SCRIPT="$(dirname "$0")/../../cloud/lib/vm-startup.sh"

gcloud compute instances create "${VM_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --machine-type=e2-standard-4 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-standard \
  --boot-disk-auto-delete \
  --service-account="pentest-scanner@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --scopes=cloud-platform \
  --metadata="SCAN_MODE=${ENV},REGISTRY=${REGISTRY},IMAGE_TAG=${IMAGE_TAG},SCAN_PROFILE=${PROFILE},TARGET_URLS=${TARGET_URLS},GCS_BUCKET=${GCP_PROJECT}-pentest-reports,SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL},NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL},VERSION=${IMAGE_TAG}" \
  --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
  --tags=pentest-scan \
  --labels="env=${ENV},project=pentest,scan=true" \
  ${SPOT_FLAG} \
  --quiet

echo "Scan VM '${VM_NAME}' launched — will self-terminate after scan"
