#!/usr/bin/env bash
set -euo pipefail

# Hybrid deploy:
#   development — no Docker, clone mode (handled by promote.yaml)
#   staging — trigger scan with baked image
#   main — tag scanner:staging as scanner:production (zero rebuild)

BRANCH="${CI_COMMIT_BRANCH}"
REGISTRY="${DOCKER_REGISTRY:?DOCKER_REGISTRY not set}"

case "$BRANCH" in
  staging)
    echo "=== Triggering staging scan with baked image ==="
    scripts/woodpecker/trigger-scan.sh staging standard
    ;;
  main)
    echo "=== Promoting scanner:staging → scanner:production (by digest) ==="
    gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

    # Resolve staging digest — ensures exact bytes get promoted
    STAGING_DIGEST=$(gcloud artifacts docker images describe \
      "${REGISTRY}/scanner:staging" \
      --format='value(image_summary.digest)' 2>/dev/null || echo "")

    if [ -z "$STAGING_DIGEST" ]; then
      echo "ERROR: Could not resolve scanner:staging digest — aborting promotion"
      exit 1
    fi

    echo "Staging digest: ${STAGING_DIGEST}"
    gcloud artifacts docker tags add \
      "${REGISTRY}/scanner@${STAGING_DIGEST}" \
      "${REGISTRY}/scanner:production"
    echo "scanner:production → ${STAGING_DIGEST}"
    ;;
  *)
    echo "No deployment for branch: $BRANCH"
    ;;
esac
