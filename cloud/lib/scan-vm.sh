#!/usr/bin/env bash
set -euo pipefail

# Launch an ephemeral VM to run a scan and self-terminate
# Usage: scan-vm.sh <environment> [profile] [image_tag]
#   environment: staging | production
#   profile:     quick | standard | thorough (default: standard)
#   image_tag:   Docker image tag (default: latest)

source "$(dirname "$0")/config.sh"

ENV="${1:?Usage: scan-vm.sh <staging|production> [profile] [image_tag]}"
PROFILE="${2:-standard}"
IMAGE_TAG="${3:-latest}"

# Environment-specific configuration
case "$ENV" in
  staging)
    TARGET_URLS='["https://auxscan.stage.data-estate.cloud"]'
    VM_SCAN_NAME="pentest-scan-staging-$(date +%Y%m%d-%H%M%S)"
    SPOT_FLAG=""
    ;;
  production)
    TARGET_URLS='["https://auxscan.app.data-estate.cloud"]'
    VM_SCAN_NAME="pentest-scan-prod-$(date +%Y%m%d-%H%M%S)"
    SPOT_FLAG="--provisioning-model=SPOT --instance-termination-action=DELETE"
    ;;
  *)
    log_error "Unknown environment: ${ENV}. Use 'staging' or 'production'."
    exit 1
    ;;
esac

# Read secrets for metadata (webhook URL, notification email)
SLACK_WEBHOOK_URL=""
NOTIFICATION_EMAIL=""
if [ -f "${PROJECT_ROOT}/.env" ]; then
  SLACK_WEBHOOK_URL=$(grep "^SLACK_WEBHOOK_URL=" "${PROJECT_ROOT}/.env" | cut -d= -f2- || echo "")
  NOTIFICATION_EMAIL=$(grep "^NOTIFICATION_EMAIL=" "${PROJECT_ROOT}/.env" | cut -d= -f2- || echo "")
fi

# Get VERSION from git or env
VERSION="${VERSION:-$(git -C "${PROJECT_ROOT}" describe --tags --always 2>/dev/null || git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"

log_info "Launching ${ENV} scan VM: ${VM_SCAN_NAME}"
log_info "  Profile: ${PROFILE}"
log_info "  Target: ${TARGET_URLS}"
log_info "  Image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
log_info "  Version: ${VERSION}"

# Create the ephemeral VM
gcloud compute instances create "${VM_SCAN_NAME}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --machine-type="${VM_MACHINE_TYPE}" \
  --image-family="${VM_IMAGE_FAMILY}" \
  --image-project="${VM_IMAGE_PROJECT}" \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-standard \
  --boot-disk-auto-delete \
  --service-account="${VM_SERVICE_ACCOUNT}" \
  --scopes=cloud-platform \
  --metadata="SCAN_MODE=${ENV},REGISTRY=${REGISTRY},IMAGE_TAG=${IMAGE_TAG},SCAN_PROFILE=${PROFILE},TARGET_URLS=${TARGET_URLS},GCS_BUCKET=${GCP_PROJECT}-pentest-reports,SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL},NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL},VERSION=${VERSION}" \
  --metadata-from-file=startup-script="${CLOUD_DIR}/lib/vm-startup.sh" \
  --tags=pentest-scan \
  --labels="env=${ENV},project=pentest,scan=true" \
  --no-address \
  ${SPOT_FLAG} \
  --quiet

log_ok "Scan VM '${VM_SCAN_NAME}' launched"
log_info "VM will self-terminate after scan completes"
log_info "Monitor: gcloud compute instances describe ${VM_SCAN_NAME} --zone=${GCP_ZONE} --project=${GCP_PROJECT}"
