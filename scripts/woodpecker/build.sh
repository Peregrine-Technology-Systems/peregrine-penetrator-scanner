#!/usr/bin/env bash
set -euo pipefail

# Build and push the baked scanner image for staging
# This image becomes production via tag promotion (no rebuild)

if [ -z "${DOCKER_REGISTRY:-}" ]; then
  echo "DOCKER_REGISTRY not set"
  exit 1
fi

gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

echo "=== Building baked scanner image ==="
echo "  Base: ${DOCKER_REGISTRY}/scanner-base:latest"
echo "  Tag: staging"

docker buildx build \
  -f docker/Dockerfile \
  --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY}" \
  -t "${DOCKER_REGISTRY}/scanner:staging" \
  --push \
  .

echo "=== Build complete — scanner:staging pushed ==="
