#!/usr/bin/env bash
set -euo pipefail

# Version bump on main merge:
# 1. Scan commits since last tag for bump type:
#    - feat!: or BREAKING CHANGE → major
#    - feat: → minor
#    - everything else → patch
# 2. Increment VERSION
# 3. Update RELEASE_NOTES — rename ## Unreleased to ## vX.Y.Z, re-seed a fresh
#    ## Unreleased above so future PRs have a target section
# 4. Commit + tag
# 5. Create GitHub Release with the notes body (every tag gets a Release)
# 6. Tag Docker image (scanner:staging → scanner:vX.Y.Z + scanner:production)

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping version bump"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Guard: skip version bump for automated commits (prevents infinite loop).
# Anchor on the SUBJECT line only (head -n1) — matching the full multi-line
# message fires the guard on any merge commit whose body happens to contain
# "release: v…" / "Sync:" on line 2+ (e.g. a PR body quoting a prior release
# line), silently skipping a real release. Reference: identity v0.1.85 (#673).
COMMIT_MSG="${CI_COMMIT_MESSAGE:-}"
COMMIT_SUBJECT=$(printf '%s' "$COMMIT_MSG" | head -n 1)
if echo "$COMMIT_SUBJECT" | grep -qE '^release: v[0-9]'; then
  echo "Skipping — version-bump commit (prevents loop)"
  exit 0
fi
if echo "$COMMIT_SUBJECT" | grep -qiE '^Sync:|sync/version-|version files to'; then
  echo "Skipping — sync-back commit"
  exit 0
fi
if echo "$COMMIT_SUBJECT" | grep -qE '^docs:|^docs\('; then
  echo "Skipping — documentation-only commit"
  exit 0
fi

# Unshallow clone to access tags (Woodpecker clones with --depth 1)
git fetch --unshallow 2>/dev/null || git fetch --tags 2>/dev/null || true

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

# Guard: skip if Unreleased section is empty (no content to release)
UNRELEASED_CONTENT=$(sed -n '/^## Unreleased$/,/^## /{/^## /d; /^$/d; p}' RELEASE_NOTES.md 2>/dev/null || echo "")
if [ -z "$UNRELEASED_CONTENT" ]; then
  # Double-check: are there untagged content commits?
  CONTENT_COMMITS=$(echo "$COMMITS" | grep -cvE '^release:|^Sync:|^Merge|^docs:|^chore:' || true)
  if [ "$CONTENT_COMMITS" = "0" ]; then
    echo "Skipping — no unreleased content and no untagged content commits"
    exit 0
  fi
  # Drift detection (MUST): ## Unreleased is empty BUT substantive commits exist
  # since the last tag. A RELEASE_NOTES write was missed — fail loudly rather
  # than silently tag an empty release. Silent-OK counterpart to the empty
  # guard above (global standard: identity version-bump.sh lines 140-152).
  echo "ERROR: ## Unreleased is empty but ${CONTENT_COMMITS} content commit(s) exist since ${LAST_TAG:-repo start}." >&2
  echo "       RELEASE_NOTES.md was not updated for shipped work — refusing to tag an empty release." >&2
  exit 1
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

# Update RELEASE_NOTES.md — rename current ## Unreleased to ## vX.Y.Z, and insert
# a fresh empty ## Unreleased above so future PRs have a target section.
# Without the fresh Unreleased re-seed, subsequent PRs add items with no section
# header, and the next bump renames an already-empty section (issue #753).
DATE=$(date +%Y-%m-%d)
if grep -q '^## Unreleased$' RELEASE_NOTES.md; then
  # GNU sed: \n in replacement works on Linux (CI runs on Linux).
  sed -i "s/^## Unreleased\$/## Unreleased\n\n## ${TAG} — ${DATE}/" RELEASE_NOTES.md
  echo "RELEASE_NOTES: renamed ## Unreleased → ## ${TAG} — ${DATE}, seeded fresh ## Unreleased"
else
  # No Unreleased heading — insert both fresh Unreleased and the new version
  # heading right after the top-level title. This self-heals repos where
  # version-bump previously consumed the Unreleased heading without re-seeding.
  sed -i "1,/^# Release Notes/{s|^# Release Notes\$|# Release Notes\n\n## Unreleased\n\n## ${TAG} — ${DATE}|}" RELEASE_NOTES.md
  echo "RELEASE_NOTES: no Unreleased section found — self-healed, added fresh ## Unreleased + ## ${TAG}"
fi

# Extract release notes content for the new version (between ## vX.Y.Z and the next ## heading)
RELEASE_BODY=$(awk -v tag="## ${TAG} — ${DATE}" '
  $0 == tag { capture = 1; next }
  capture && /^## / { exit }
  capture { print }
' RELEASE_NOTES.md)

# Commit all version changes
git config user.name "woodpecker-ci[bot]"
git config user.email "woodpecker-ci[bot]@users.noreply.github.com"

# Set push URL with token (Woodpecker clone uses HTTPS without push credentials)
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"

# --- PR-based flow (Pattern A: enforce_admins blocks direct push to main) ---
# Commit the bump on a release branch, PR → main, merge + tag via the API.
# Mirrors peregrine-platform-ioi/scripts/woodpecker/version-bump.sh, including
# the mergeable-race guards (ioi#266) and stale-branch delete (ioi#31).
RELEASE_BRANCH="release/${TAG}"

# Delete any stale remote release branch from a previous killed run before
# pushing — otherwise restarts after agent disconnect fail non-fast-forward.
git push origin --delete "${RELEASE_BRANCH}" 2>/dev/null || true

git checkout -b "${RELEASE_BRANCH}"
git add VERSION RELEASE_NOTES.md
git commit -m "release: ${TAG}

Bump: ${BUMP_TYPE} (${CURRENT} → ${NEW_VERSION})

Co-Authored-By: woodpecker-ci[bot] <woodpecker-ci[bot]@users.noreply.github.com>"
git push origin "${RELEASE_BRANCH}"

# Create the release PR via API
PR_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/pulls" \
  -d "$(jq -n --arg t "release: ${TAG}" --arg h "${RELEASE_BRANCH}" \
    --arg b "Automated version bump: ${BUMP_TYPE} (${CURRENT} → ${NEW_VERSION})" \
    '{title: $t, head: $h, base: "main", body: $b}')")
PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number')
if [ "$PR_NUMBER" = "null" ] || [ -z "$PR_NUMBER" ]; then
  echo "ERROR: Failed to create release PR"
  echo "$PR_RESPONSE" | jq -r '.message // .errors[0].message // "unknown error"'
  exit 1
fi
echo "Created release PR #${PR_NUMBER}"

# GitHub computes .mergeable asynchronously (null while computing). Merging in
# that window returns a misleading 409 "Base branch was modified". Poll up to
# 30s for it to settle, then merge with up to 3 retries on that race only.
for attempt in $(seq 1 30); do
  PR_STATE=$(curl -s -H "$AUTH" "${API}/repos/${REPO}/pulls/${PR_NUMBER}")
  MERGEABLE=$(echo "$PR_STATE" | jq -r '.mergeable')
  MSTATE=$(echo "$PR_STATE" | jq -r '.mergeable_state')
  if [ "$MERGEABLE" = "true" ] && [ "$MSTATE" = "clean" ]; then
    echo "PR #${PR_NUMBER} mergeable after ${attempt}s"
    break
  fi
  if [ "$attempt" = "30" ]; then
    echo "ERROR: PR #${PR_NUMBER} not mergeable after 30s — mergeable=${MERGEABLE} state=${MSTATE}"
    exit 1
  fi
  sleep 1
done

MERGED=""
MERGE_RESPONSE=""
for attempt in 1 2 3; do
  MERGE_RESPONSE=$(curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
    -d "{\"merge_method\": \"merge\", \"commit_title\": \"release: ${TAG}\"}")
  MERGED=$(echo "$MERGE_RESPONSE" | jq -r '.merged')
  [ "$MERGED" = "true" ] && break
  MSG=$(echo "$MERGE_RESPONSE" | jq -r '.message // ""')
  echo "Merge attempt ${attempt} failed: ${MSG}"
  echo "$MSG" | grep -q "Base branch was modified" || break
  sleep $((attempt * 2))
done
if [ "$MERGED" != "true" ]; then
  echo "ERROR: Failed to merge release PR #${PR_NUMBER} after retries"
  exit 1
fi
echo "Merged release PR #${PR_NUMBER}"

# Tag the merge commit via API (not git tag — works with enforce_admins)
MERGE_SHA=$(echo "$MERGE_RESPONSE" | jq -r '.sha')
TAG_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/git/refs" \
  -d "$(jq -n --arg ref "refs/tags/${TAG}" --arg sha "${MERGE_SHA}" '{ref: $ref, sha: $sha}')")
if echo "$TAG_RESPONSE" | jq -e '.ref == "refs/tags/'"${TAG}"'"' >/dev/null 2>&1; then
  echo "Created tag ${TAG} → ${MERGE_SHA}"
else
  echo "ERROR: Tag creation failed: $(echo "$TAG_RESPONSE" | jq -r '.message // "unknown"')"
  exit 1
fi

# Create GitHub Release — every tag must have a corresponding Release (no orphan tags).
# Body is the RELEASE_NOTES section extracted above.
RELEASE_PAYLOAD=$(jq -n \
  --arg tag "${TAG}" \
  --arg name "${TAG}" \
  --arg body "${RELEASE_BODY:-No release notes captured.}" \
  '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}')

RELEASE_RESPONSE=$(curl -s -o /tmp/release-response.json -w "%{http_code}" \
  -X POST -H "$AUTH" -H "Accept: application/vnd.github+json" \
  "${API}/repos/${REPO}/releases" \
  -d "${RELEASE_PAYLOAD}")

if [ "$RELEASE_RESPONSE" = "201" ]; then
  echo "Created GitHub Release: ${TAG}"
else
  echo "WARNING: Failed to create GitHub Release (HTTP ${RELEASE_RESPONSE})"
  cat /tmp/release-response.json
fi

# #767: fire GitHub Deployment API for the new tag (cross-repo rollout #1187).
# Triggers release.yaml via the deployment webhook on event=deployment.
# Best-effort — failure here doesn't block the release.
echo "Firing GitHub Deployment for ${TAG} → triggers release.yaml via deployment webhook"
DEPLOY_PAYLOAD=$(jq -n --arg ref "$TAG" --arg desc "Auto-deploy of ${TAG} triggered by main merge" '{
  ref: $ref,
  environment: "production",
  auto_merge: false,
  required_contexts: [],
  description: $desc,
  production_environment: true
}')
DEPLOY_RESPONSE=$(curl -sS -X POST -H "$AUTH" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/deployments" \
  -d "$DEPLOY_PAYLOAD")
DEPLOY_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.id // empty')
if [ -n "$DEPLOY_ID" ] && [ "$DEPLOY_ID" != "null" ]; then
  echo "Created Deployment id=${DEPLOY_ID} for ${TAG}"
else
  echo "WARNING: Deployment API call did not return an id — release.yaml may not fire"
  echo "$DEPLOY_RESPONSE" | jq -r '.message // .' 2>/dev/null || echo "$DEPLOY_RESPONSE"
fi

# Tag Docker image by DIGEST: scanner:staging → scanner:vX.Y.Z + scanner:production
# Using digest ensures the exact bytes that passed staging CI get promoted,
# even if the staging tag was re-pointed by a concurrent build.
if [ -n "${DOCKER_REGISTRY:-}" ]; then
  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

  STAGING_DIGEST=$(gcloud artifacts docker images describe \
    "${DOCKER_REGISTRY}/scanner:staging" \
    --format='value(image_summary.digest)' 2>/dev/null || echo "")

  if [ -n "$STAGING_DIGEST" ]; then
    echo "Staging digest: ${STAGING_DIGEST}"

    echo "Tagging scanner@${STAGING_DIGEST} as scanner:${TAG}"
    gcloud artifacts docker tags add \
      "${DOCKER_REGISTRY}/scanner@${STAGING_DIGEST}" \
      "${DOCKER_REGISTRY}/scanner:${TAG}" 2>/dev/null || echo "WARNING: Could not tag scanner:${TAG}"

    echo "Tagging scanner@${STAGING_DIGEST} as scanner:production"
    gcloud artifacts docker tags add \
      "${DOCKER_REGISTRY}/scanner@${STAGING_DIGEST}" \
      "${DOCKER_REGISTRY}/scanner:production" 2>/dev/null || echo "WARNING: Could not tag scanner:production"
  else
    echo "WARNING: Could not resolve staging digest — falling back to tag-based promotion"
    gcloud artifacts docker tags add \
      "${DOCKER_REGISTRY}/scanner:staging" \
      "${DOCKER_REGISTRY}/scanner:${TAG}" 2>/dev/null || echo "WARNING: Could not tag scanner:${TAG}"
    gcloud artifacts docker tags add \
      "${DOCKER_REGISTRY}/scanner:staging" \
      "${DOCKER_REGISTRY}/scanner:production" 2>/dev/null || echo "WARNING: Could not tag scanner:production"
  fi
fi

# Send an informational Slack notification for the tag — NOT a celebration.
# The gold "PRODUCTION RELEASE" message should only fire after successful
# deployment, which is handled by the deploy pipeline's notify-status.sh (#367)
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  COMMIT_URL="https://github.com/${REPO}/commit/$(git rev-parse HEAD)"
  SHORT_SHA=$(git rev-parse --short HEAD)
  WOODPECKER_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"
  REPO_NAME="${REPO##*/}"
  REPO_URL="https://github.com/${REPO}"

  curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"text\": \"Tagged ${TAG} — ${REPO_NAME} — deploying...\",
      \"attachments\": [
        {
          \"color\": \"#6c757d\",
          \"blocks\": [
            {
              \"type\": \"section\",
              \"text\": {
                \"type\": \"mrkdwn\",
                \"text\": \":label: *Tagged ${TAG}* — *<${REPO_URL}|${REPO_NAME}>*\n*Bump:* ${BUMP_TYPE} (${CURRENT} → ${NEW_VERSION})\n*Commit:* <${COMMIT_URL}|\`${SHORT_SHA}\`>\n<${WOODPECKER_URL}|View pipeline>\"
              }
            }
          ]
        }
      ]
    }" || echo "Warning: Slack notification failed"
fi

echo "=== Release ${TAG} complete ==="
