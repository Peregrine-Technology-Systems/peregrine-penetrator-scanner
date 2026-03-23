#!/usr/bin/env bash
set -euo pipefail

# Launch an ephemeral scan VM on GCP
# Usage: trigger-scan.sh <development|staging|production> <profile>
#
# The VM pulls scanner-base (tools image), clones app code at the
# matching branch, installs gems, and runs the scan.

ENV="${1:?Usage: trigger-scan.sh <development|staging|production> <profile>}"
PROFILE="${2:-standard}"

GCP_PROJECT="${GCP_PROJECT:-peregrine-pentest-dev}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
REGISTRY="${DOCKER_REGISTRY:-us-central1-docker.pkg.dev/${GCP_PROJECT}/pentest}"
VM_NAME="pentest-scan-${ENV}-$(date +%Y%m%d-%H%M%S)"

# Map environment to git branch
case "$ENV" in
  development)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="auxscan-dev"
    BRANCH="development"
    SPOT_FLAG=""
    ;;
  staging)
    TARGET_URLS='["https://auxscan.stage.data-estate.cloud"]'
    TARGET_NAME="auxscan-staging"
    BRANCH="staging"
    SPOT_FLAG=""
    ;;
  production)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    TARGET_NAME="auxscan-production"
    BRANCH="main"
    SPOT_FLAG="--provisioning-model=SPOT --instance-termination-action=DELETE"
    ;;
  *)
    echo "Unknown environment: ${ENV}"
    exit 1
    ;;
esac

# Notification secrets from Woodpecker env (injected via from_secret)
SLACK_URL="${SLACK_WEBHOOK_URL:-}"
EMAIL="${NOTIFICATION_EMAIL:-}"

echo "Launching ${ENV} scan VM: ${VM_NAME}"
echo "  Base image: ${REGISTRY}/scanner-base:latest"
echo "  App branch: ${BRANCH}"
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
  --metadata="SCAN_MODE=${ENV},REGISTRY=${REGISTRY},IMAGE_TAG=${BRANCH},SCAN_PROFILE=${PROFILE},TARGET_NAME=${TARGET_NAME},TARGET_URLS=${TARGET_URLS},GCS_BUCKET=${GCP_PROJECT}-pentest-reports,SLACK_WEBHOOK_URL=${SLACK_URL},NOTIFICATION_EMAIL=${EMAIL},VERSION=${BRANCH}" \
  --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
  --tags=pentest-scan \
  --labels="env=${ENV},project=pentest,scan=true" \
  ${SPOT_FLAG} \
  --quiet

echo "Scan VM '${VM_NAME}' launched — will self-terminate after scan"
