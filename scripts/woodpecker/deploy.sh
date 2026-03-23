#!/usr/bin/env bash
set -euo pipefail

# Tag Docker images per environment + trigger scans
# development: promote to staging (handled by promote.yaml)
# staging: tag image as staging, trigger scan
# main: tag image as production

BRANCH="${CI_COMMIT_BRANCH}"
SHORT_SHA="${CI_COMMIT_SHA:0:7}"

case "$BRANCH" in
  development)
    # Build already pushed in build.yaml — nothing to tag
    echo "Development build complete — promotion handled by promote.yaml"
    exit 0
    ;;
  staging)
    ENV="staging"
    GCP_PROJECT="${GCP_PROJECT_STG:?GCP_PROJECT_STG not set}"
    IMAGE_TAG="staging"
    ;;
  main)
    ENV="production"
    GCP_PROJECT="${GCP_PROJECT_PRD:?GCP_PROJECT_PRD not set}"
    IMAGE_TAG="production"
    ;;
  *)
    echo "No deployment for branch: $BRANCH"
    exit 0
    ;;
esac

DOCKER_REGISTRY="${DOCKER_REGISTRY:?DOCKER_REGISTRY not set}"

echo "=== Tagging scanner image for ${ENV} ==="
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

if gcloud artifacts docker images describe "${DOCKER_REGISTRY}/scanner:${SHORT_SHA}" 2>/dev/null; then
  SOURCE_TAG="${SHORT_SHA}"
else
  echo "Commit tag not found, using latest"
  SOURCE_TAG="latest"
fi

gcloud artifacts docker tags add \
  "${DOCKER_REGISTRY}/scanner:${SOURCE_TAG}" \
  "${DOCKER_REGISTRY}/scanner:${IMAGE_TAG}" || echo "Tag failed — image may not exist yet"

# Trigger scan on staging
if [ "$BRANCH" = "staging" ]; then
  echo "=== Triggering staging scan ==="
  scripts/woodpecker/trigger-scan.sh staging standard staging
fi

echo "=== Deploy complete for ${ENV} ==="
