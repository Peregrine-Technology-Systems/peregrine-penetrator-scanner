#!/usr/bin/env bash
set -euo pipefail

# Build and push the baked scanner image for staging
# This image becomes production via tag promotion (no rebuild)

if [ -z "${DOCKER_REGISTRY:-}" ]; then
  echo "DOCKER_REGISTRY not set"
  exit 1
fi

gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

# Bake the build commit into the image so the running scan can prove which bits
# it executed (smoke-test asserts envelope scanner_commit == this commit).
COMMIT_SHA="${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"

echo "=== Building baked scanner image ==="
echo "  Base: ${DOCKER_REGISTRY}/scanner-base:latest"
echo "  Tag: staging"
echo "  Commit: ${COMMIT_SHA}"

docker buildx build \
  -f docker/Dockerfile \
  --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY}" \
  --build-arg "GIT_COMMIT=${COMMIT_SHA}" \
  -t "${DOCKER_REGISTRY}/scanner:staging" \
  --push \
  .

# Also tag with commit SHA for traceability
docker buildx build \
  -f docker/Dockerfile \
  --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY}" \
  --build-arg "GIT_COMMIT=${COMMIT_SHA}" \
  -t "${DOCKER_REGISTRY}/scanner:${COMMIT_SHA}" \
  --push \
  . 2>/dev/null || echo "WARNING: Could not push SHA-tagged image"

# Verify the image can boot and load gems
echo "=== Verifying scanner:staging image ==="
docker pull "${DOCKER_REGISTRY}/scanner:staging"
VERIFY_OUTPUT=$(docker run --rm "${DOCKER_REGISTRY}/scanner:staging" \
  bundle exec ruby -e "require 'sequel'; require 'faraday'; puts 'VERIFY_OK'" 2>&1 || echo "VERIFY_FAILED")

if echo "$VERIFY_OUTPUT" | grep -q "VERIFY_OK"; then
  echo "Image verification passed — gems load correctly"
else
  echo "ERROR: Image verification FAILED — gems do not load"
  echo "$VERIFY_OUTPUT"
  exit 1
fi

echo "=== Build complete — scanner:staging pushed and verified ==="
