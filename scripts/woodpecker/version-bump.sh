#!/usr/bin/env bash
set -euo pipefail

# Version bump on main merge:
# 1. Scan commits since last tag for bump type:
#    - feat!: or BREAKING CHANGE → major
#    - feat: → minor
#    - everything else → patch
# 2. Increment VERSION
# 3. Update RELEASE_NOTES — move Unreleased items under version header
# 4. Commit + tag
# 5. Tag Docker image (scanner:staging → scanner:vX.Y.Z + scanner:production)

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping version bump"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Guard: skip if this pipeline was triggered by a version-bump commit (prevents infinite loop)
COMMIT_MSG="${CI_COMMIT_MESSAGE:-}"
if echo "$COMMIT_MSG" | grep -qE '^release: v[0-9]'; then
  echo "Skipping — this commit is a version-bump commit (prevents loop)"
  exit 0
fi

# Read current version
if [ ! -f VERSION ]; then
  echo "ERROR: VERSION file not found"
  exit 1
fi

CURRENT=$(cat VERSION | tr -d '[:space:]')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

# Determine bump type from commits since last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
  COMMITS=$(git log "${LAST_TAG}..HEAD" --pretty=format:"%s" 2>/dev/null || echo "")
else
  COMMITS=$(git log --pretty=format:"%s" 2>/dev/null || echo "")
fi

BUMP_TYPE="patch"
if echo "$COMMITS" | grep -qE '^feat!:|BREAKING CHANGE'; then
  BUMP_TYPE="major"
elif echo "$COMMITS" | grep -qE '^feat:'; then
  BUMP_TYPE="minor"
fi

# Increment version
case "$BUMP_TYPE" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${NEW_VERSION}"

echo "=== Version Bump: ${CURRENT} → ${NEW_VERSION} (${BUMP_TYPE}) ==="

# Check if tag already exists (idempotent)
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH" "${API}/repos/${REPO}/git/refs/tags/${TAG}")
if [ "$EXISTING" = "200" ]; then
  echo "Tag ${TAG} already exists — skipping"
  exit 0
fi

# Update VERSION file
echo "${NEW_VERSION}" > VERSION
echo "VERSION: ${CURRENT} → ${NEW_VERSION}"

# Update RELEASE_NOTES.md — replace ## Unreleased with ## vX.Y.Z — date
DATE=$(date +%Y-%m-%d)
if grep -q '^## Unreleased' RELEASE_NOTES.md; then
  sed -i "s/^## Unreleased$/## ${TAG} — ${DATE}/" RELEASE_NOTES.md
  echo "RELEASE_NOTES: ## Unreleased → ## ${TAG} — ${DATE}"
else
  echo "WARNING: No ## Unreleased section found in RELEASE_NOTES.md"
fi

# Commit all version changes
git config user.name "woodpecker-ci[bot]"
git config user.email "woodpecker-ci[bot]@users.noreply.github.com"

# Set push URL with token (Woodpecker clone uses HTTPS without push credentials)
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"

git add VERSION RELEASE_NOTES.md
git commit -m "release: ${TAG}

Bump: ${BUMP_TYPE} (${CURRENT} → ${NEW_VERSION})

Co-Authored-By: woodpecker-ci[bot] <woodpecker-ci[bot]@users.noreply.github.com>"
git push origin main

# Create tag
git tag -a "${TAG}" -m "Release ${TAG}"
git push origin "${TAG}"
echo "Created and pushed tag: ${TAG}"

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

# Send the production release Slack notification directly (notify-status would
# read stale CI_COMMIT_MESSAGE from the triggering merge, not from our release commit)
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  COMMIT_URL="https://github.com/${REPO}/commit/$(git rev-parse HEAD)"
  SHORT_SHA=$(git rev-parse --short HEAD)
  WOODPECKER_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"
  REPO_NAME="${REPO##*/}"
  REPO_URL="https://github.com/${REPO}"

  curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"text\": \":rocket::rocket::rocket: PRODUCTION RELEASE ${TAG} — ${REPO_NAME}\",
      \"blocks\": [
        {\"type\": \"divider\"},
        {
          \"type\": \"header\",
          \"text\": {\"type\": \"plain_text\", \"text\": \":rocket: PRODUCTION RELEASE ${TAG}\", \"emoji\": true}
        },
        {
          \"type\": \"section\",
          \"text\": {
            \"type\": \"mrkdwn\",
            \"text\": \"*<${REPO_URL}|${REPO_NAME}>* deployed to production\n\n*Version:* \`${TAG}\`\n*Commit:* <${COMMIT_URL}|\`${SHORT_SHA}\`> — release: ${TAG}\n*Bump:* ${BUMP_TYPE} (${CURRENT} → ${NEW_VERSION})\n*Pipeline:* <${WOODPECKER_URL}|View in Woodpecker>\"
          }
        },
        {\"type\": \"divider\"}
      ]
    }" || echo "Warning: Slack notification failed"
fi

echo "=== Release ${TAG} complete ==="
