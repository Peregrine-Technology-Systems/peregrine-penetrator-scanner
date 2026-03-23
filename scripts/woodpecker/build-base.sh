#!/usr/bin/env bash
set -euo pipefail

# Build and push the scanner-base image (security tools + runtime)
# Only runs when docker/Dockerfile.base or docker/base-versions.txt changes

if [ -z "${DOCKER_REGISTRY:-}" ]; then
  echo "DOCKER_REGISTRY not set"
  exit 1
fi

gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

# Read pinned versions from manifest
VERSIONS_FILE="docker/base-versions.txt"
if [ -f "$VERSIONS_FILE" ]; then
  NUCLEI_VERSION=$(grep NUCLEI_VERSION "$VERSIONS_FILE" | cut -d= -f2)
  FFUF_VERSION=$(grep FFUF_VERSION "$VERSIONS_FILE" | cut -d= -f2)
  echo "Tool versions from ${VERSIONS_FILE}:"
  echo "  Nuclei: ${NUCLEI_VERSION}"
  echo "  ffuf:   ${FFUF_VERSION}"
fi

echo "=== Building scanner-base image ==="

docker buildx build \
  -f docker/Dockerfile.base \
  --build-arg "NUCLEI_VERSION=${NUCLEI_VERSION:-3.7.1}" \
  --build-arg "FFUF_VERSION=${FFUF_VERSION:-2.1.0}" \
  -t "${DOCKER_REGISTRY}/scanner-base:latest" \
  --push \
  .

echo "=== scanner-base build complete ==="
