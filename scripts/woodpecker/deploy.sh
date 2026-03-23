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
    echo "=== Promoting scanner:staging → scanner:production ==="
    gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
    gcloud artifacts docker tags add \
      "${REGISTRY}/scanner:staging" \
      "${REGISTRY}/scanner:production"
    echo "scanner:production now points to the same image as scanner:staging"
    ;;
  *)
    echo "No deployment for branch: $BRANCH"
    ;;
esac
