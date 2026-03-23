#!/usr/bin/env bash
set -euo pipefail

# Version bump on main merge:
# 1. Read VERSION file
# 2. Check if tag already exists (idempotent)
# 3. Update RELEASE_NOTES — move Unreleased items under version header
# 4. Create git tag
# 5. Tag Docker image (scanner:staging → scanner:vX.Y.Z + scanner:production)

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping version bump"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Read version from VERSION file
if [ ! -f VERSION ]; then
  echo "ERROR: VERSION file not found"
  exit 1
fi

VERSION=$(cat VERSION | tr -d '[:space:]')
TAG="v${VERSION}"

echo "=== Version Bump: ${TAG} ==="

# Check if tag already exists
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH" "${API}/repos/${REPO}/git/refs/tags/${TAG}")
if [ "$EXISTING" = "200" ]; then
  echo "Tag ${TAG} already exists — skipping"
  exit 0
fi

# Update RELEASE_NOTES.md — replace ## Unreleased with ## vX.Y.Z — date
DATE=$(date +%Y-%m-%d)
if grep -q '^## Unreleased' RELEASE_NOTES.md; then
  sed -i "s/^## Unreleased$/## ${TAG} — ${DATE}/" RELEASE_NOTES.md
  echo "Updated RELEASE_NOTES.md: ## Unreleased → ## ${TAG} — ${DATE}"
else
  echo "WARNING: No ## Unreleased section found in RELEASE_NOTES.md"
fi

# Commit the RELEASE_NOTES update
git config user.name "woodpecker-ci[bot]"
git config user.email "woodpecker-ci[bot]@users.noreply.github.com"

git add RELEASE_NOTES.md
if ! git diff --cached --quiet; then
  git commit -m "release: ${TAG}

Co-Authored-By: woodpecker-ci[bot] <woodpecker-ci[bot]@users.noreply.github.com>"
  git push origin main
fi

# Create tag
git tag -a "${TAG}" -m "Release ${TAG}"
git push origin "${TAG}"
echo "Created tag: ${TAG}"

# Tag Docker image: scanner:staging → scanner:vX.Y.Z + scanner:production
if [ -n "${DOCKER_REGISTRY:-}" ]; then
  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

  echo "Tagging scanner:staging as scanner:${TAG}"
  gcloud artifacts docker tags add \
    "${DOCKER_REGISTRY}/scanner:staging" \
    "${DOCKER_REGISTRY}/scanner:${TAG}" 2>/dev/null || echo "WARNING: Could not tag scanner:${TAG}"

  echo "Tagging scanner:staging as scanner:production"
  gcloud artifacts docker tags add \
    "${DOCKER_REGISTRY}/scanner:staging" \
    "${DOCKER_REGISTRY}/scanner:production" 2>/dev/null || echo "WARNING: Could not tag scanner:production"
fi

echo "=== Release ${TAG} complete ==="
