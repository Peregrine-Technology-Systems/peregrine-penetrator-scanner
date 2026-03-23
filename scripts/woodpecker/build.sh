#!/usr/bin/env bash
set -euo pipefail

# Build and push Docker image to Artifact Registry

if [ -z "${DOCKER_REGISTRY:-}" ]; then
  echo "DOCKER_REGISTRY not set"
  exit 1
fi

gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

SHORT_SHA="${CI_COMMIT_SHA:0:7}"

echo "=== Building scanner image ==="
echo "  Registry: ${DOCKER_REGISTRY}"
echo "  Tags: ${SHORT_SHA}, latest"

# Use buildx with registry cache for faster builds
docker buildx create --name ci-builder --use 2>/dev/null || docker buildx use ci-builder 2>/dev/null || true

docker buildx build \
  --cache-from "type=registry,ref=${DOCKER_REGISTRY}/scanner:buildcache" \
  --cache-to "type=registry,ref=${DOCKER_REGISTRY}/scanner:buildcache,mode=max" \
  -f docker/Dockerfile \
  -t "${DOCKER_REGISTRY}/scanner:${SHORT_SHA}" \
  -t "${DOCKER_REGISTRY}/scanner:latest" \
  --push \
  .

echo "=== Build complete ==="
