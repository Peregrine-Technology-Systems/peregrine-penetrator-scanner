#!/usr/bin/env bash
set -euo pipefail

# Build and push Docker image to Artifact Registry

if [ -z "${DOCKER_REGISTRY:-}" ]; then
  echo "DOCKER_REGISTRY not set"
  exit 1
fi

gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

SHORT_SHA="${CI_COMMIT_SHA:0:7}"

echo "=== Building scanner app image ==="
echo "  Base: ${DOCKER_REGISTRY}/scanner-base:latest"
echo "  Tags: ${SHORT_SHA}, latest"

docker buildx build \
  -f docker/Dockerfile \
  --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY}" \
  -t "${DOCKER_REGISTRY}/scanner:${SHORT_SHA}" \
  -t "${DOCKER_REGISTRY}/scanner:latest" \
  --push \
  .

echo "=== Build complete ==="
