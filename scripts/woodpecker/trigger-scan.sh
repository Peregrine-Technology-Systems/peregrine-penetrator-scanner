#!/usr/bin/env bash
set -euo pipefail

# Launch an ephemeral scan VM on GCP
# Usage: trigger-scan.sh <development|staging|production> <profile>
#
# Hybrid model:
#   development → VM clones code + bundle install (IMAGE_TAG=development)
#   staging     → VM pulls baked scanner:staging image (IMAGE_TAG=staging)
#   production  → VM pulls baked scanner:production image (IMAGE_TAG=production)

ENV="${1:?Usage: trigger-scan.sh <development|staging|production> <profile>}"
PROFILE="${2:-standard}"

GCP_PROJECT="${GCP_PROJECT:-peregrine-pentest-dev}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
REGISTRY="${DOCKER_REGISTRY:-us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest}"
VM_NAME="pentest-scan-${ENV}-$(date +%Y%m%d-%H%M%S)"

case "$ENV" in
  development)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="auxscan-dev"
    IMAGE_TAG="development"
    SPOT_FLAG=""
    ;;
  staging)
    TARGET_URLS='["https://auxscan.stage.data-estate.cloud"]'
    TARGET_NAME="auxscan-staging"
    IMAGE_TAG="staging"
    SPOT_FLAG=""
    ;;
  production)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="auxscan-production"
    IMAGE_TAG="production"
    SPOT_FLAG="--provisioning-model=SPOT --instance-termination-action=DELETE"
    ;;
  *)
    echo "Unknown environment: ${ENV}"
    exit 1
    ;;
esac

SLACK_URL="${SLACK_WEBHOOK_URL:-}"
EMAIL="${NOTIFICATION_EMAIL:-}"

echo "Launching ${ENV} scan VM: ${VM_NAME}"
echo "  Image tag: ${IMAGE_TAG} ($([ "$IMAGE_TAG" = "development" ] && echo "clone mode" || echo "baked image"))"
echo "  Profile: ${PROFILE}"
echo "  Target: ${TARGET_URLS}"

STARTUP_SCRIPT="${CI_WORKSPACE}/cloud/lib/vm-startup.sh"

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
  --metadata="SCAN_MODE=${ENV},REGISTRY=${REGISTRY},IMAGE_TAG=${IMAGE_TAG},SCAN_PROFILE=${PROFILE},TARGET_NAME=${TARGET_NAME},TARGET_URLS=${TARGET_URLS},GCS_BUCKET=${GCP_PROJECT}-pentest-reports,SLACK_WEBHOOK_URL=${SLACK_URL},NOTIFICATION_EMAIL=${EMAIL},VERSION=${IMAGE_TAG}" \
  --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
  --tags=pentest-scan \
  --labels="env=${ENV},project=pentest,scan=true" \
  ${SPOT_FLAG} \
  --quiet

echo "Scan VM '${VM_NAME}' launched — will self-terminate after scan"
