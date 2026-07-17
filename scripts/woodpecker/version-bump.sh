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
# 6. The git tag fires the org-native image bake (bake.yaml) for traceability.
#    Production promotion is owned by release.yaml on the Deployment event (#808).

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping version bump"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Retries a transient non-JSON GitHub API response (e.g. GitHub's "Unicorn" 503
# HTML page — confirmed root cause, not gzip). Always returns whatever was LAST
# received — never hard-fails on its own, so callers keep their existing
# pass/fail handling unchanged. Canonical: peregrine-messaging PR #323. This
# script creates the release tag + GitHub Release, so a silent bad-JSON parse
# here is the highest-stakes case in the estate-wide broadcast (#1153): it can
# strand an orphan tag (tag with no Release, SOC 2 CC7.2 gap).
gh_api() {
  local response attempt
  for attempt in 1 2 3; do
    response=$(curl -s --compressed -H "$AUTH" "$@")
    if printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$response"
      return 0
    fi
    echo "WARNING: non-JSON response from GitHub API, attempt ${attempt}/3 (first 300 chars):" >&2
    printf '%s\n' "${response:0:300}" >&2
    [ "$attempt" -lt 3 ] && sleep 3
  done
  printf '%s' "$response"
}

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
  # Drift detected: ## Unreleased is empty BUT substantive commits exist since
  # the last tag. The usual cause on this repo is a merge=union MISFILE on the
  # manual staging→main merge (which has no cleanup pass) — entries pushed out of
  # ## Unreleased into a versioned section. Attempt a SCOPED self-heal (#850):
  # reconstruct ## Unreleased from origin/staging's live Unreleased minus the last
  # tag's released set. This runs ONLY here, on the drift-failure path — never on
  # the happy path, so a normal release never touches this code. If it can't
  # recover from a known source it falls through to the original fail-loud below
  # (never guess a release into existence).
  echo "## Unreleased empty with ${CONTENT_COMMITS} content commit(s) since ${LAST_TAG:-repo start} — attempting reconstruct from origin/staging (#850)"
  git fetch origin staging 2>/dev/null || true
  RECON_OK=0
  if [ -n "$LAST_TAG" ]; then
    git show "${LAST_TAG}:RELEASE_NOTES.md" > /tmp/vb-lasttag-rn.md 2>/dev/null || true
    git show origin/staging:RELEASE_NOTES.md > /tmp/vb-staging-rn.md 2>/dev/null || true
    if [ -s /tmp/vb-lasttag-rn.md ] && [ -s /tmp/vb-staging-rn.md ]; then
      if scripts/reconstruct-release-notes.sh RELEASE_NOTES.md /tmp/vb-lasttag-rn.md /tmp/vb-staging-rn.md; then
        RECON_OK=1
      fi
    fi
  fi
  if [ "$RECON_OK" = "1" ]; then
    UNRELEASED_CONTENT=$(sed -n '/^## Unreleased$/,/^## /{/^## /d; /^$/d; p}' RELEASE_NOTES.md 2>/dev/null || echo "")
    echo "Reconstructed ## Unreleased from origin/staging — proceeding with the recovered entries"
  fi
  if [ -z "$UNRELEASED_CONTENT" ]; then
    # Reconstruct could not recover from a known source — fail loudly rather than
    # silently tag an empty release (silent-OK counterpart to the empty guard).
    echo "ERROR: ## Unreleased is empty but ${CONTENT_COMMITS} content commit(s) exist since ${LAST_TAG:-repo start}, and reconstruct could not recover from origin/staging." >&2
    echo "       RELEASE_NOTES.md was not updated for shipped work — refusing to tag an empty release." >&2
    exit 1
  fi
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
PR_RESPONSE=$(gh_api -X POST -H "Content-Type: application/json" \
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
#
# Accept BOTH `clean` AND `unstable` (canonical ROBUST_PROMOTE_PATTERN.md poll):
#   clean    = mergeable, all required checks green
#   unstable = mergeable, required checks green, only a NON-required check
#              pending/failing (e.g. CodeQL on the release PR)
# Under Pattern A/B branch protection a non-required check never blocks the
# merge, so bailing on `unstable` strands the release for a check that doesn't
# gate it — the exact failure that stalled v0.19.0 (#775). `blocked`/`dirty`/
# `behind` are NOT accepted and keep polling until the window expires.
for attempt in $(seq 1 30); do
  PR_STATE=$(gh_api "${API}/repos/${REPO}/pulls/${PR_NUMBER}")
  MERGEABLE=$(echo "$PR_STATE" | jq -r '.mergeable')
  MSTATE=$(echo "$PR_STATE" | jq -r '.mergeable_state')
  if [ "$MERGEABLE" = "true" ] && { [ "$MSTATE" = "clean" ] || [ "$MSTATE" = "unstable" ]; }; then
    echo "PR #${PR_NUMBER} mergeable after ${attempt}s (state=${MSTATE})"
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
  MERGE_RESPONSE=$(gh_api -X PUT -H "Content-Type: application/json" \
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

# Tag the merge commit via API (not git tag — works with enforce_admins).
# Validate the SHA before tagging (#841): a null/garbage .sha parse would POST a
# bad ref that fails downstream — fail loud here instead.
MERGE_SHA=$(echo "$MERGE_RESPONSE" | jq -r '.sha')
if ! echo "$MERGE_SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "ERROR: invalid merge SHA '${MERGE_SHA}' from merge response — refusing to tag" >&2
  exit 1
fi
TAG_RESPONSE=$(gh_api -X POST -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/git/refs" \
  -d "$(jq -n --arg ref "refs/tags/${TAG}" --arg sha "${MERGE_SHA}" '{ref: $ref, sha: $sha}')")
if echo "$TAG_RESPONSE" | jq -e '.ref == "refs/tags/'"${TAG}"'"' >/dev/null 2>&1; then
  echo "Created tag ${TAG} → ${MERGE_SHA}"
elif curl -s -o /dev/null -w "%{http_code}" -H "$AUTH" \
       "${API}/repos/${REPO}/git/refs/tags/${TAG}" | grep -q '^200$'; then
  # Idempotent: a prior run (or concurrent run) already created it — converge.
  echo "Tag ${TAG} already exists — converged"
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

# Create the Release — idempotent + retried + fail-loud (#841). Every tag MUST
# have a Release (Rule #8, SOC 2 CC7.2). A transient api.github.com flake must
# not strand a tagged-but-Release-less commit (an orphan), so: GET first (skip if
# present), POST with backoff retry, re-check existence after a failed POST (a
# concurrent run may have created it), and exit 1 with a recovery command if it
# truly can't be created — never warn-and-continue.
release_exists() {
  curl -s -o /dev/null -w "%{http_code}" -H "$AUTH" \
    "${API}/repos/${REPO}/releases/tags/${TAG}" | grep -q '^200$'
}

if release_exists; then
  echo "GitHub Release ${TAG} already exists — skipping"
else
  RELEASED=false
  for attempt in 1 2 3; do
    RELEASE_RESPONSE=$(curl -s -o /tmp/release-response.json -w "%{http_code}" \
      -X POST -H "$AUTH" -H "Accept: application/vnd.github+json" \
      "${API}/repos/${REPO}/releases" \
      -d "${RELEASE_PAYLOAD}")
    if [ "$RELEASE_RESPONSE" = "201" ]; then
      echo "Created GitHub Release: ${TAG}"
      RELEASED=true
      break
    fi
    # Re-check existence — a prior attempt or concurrent run may have landed it
    # despite a flaky read of the POST response.
    if release_exists; then
      echo "GitHub Release ${TAG} now exists (converged after flake)"
      RELEASED=true
      break
    fi
    echo "Release attempt ${attempt}/3 failed (HTTP ${RELEASE_RESPONSE}):"
    cat /tmp/release-response.json
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  if [ "$RELEASED" != "true" ]; then
    echo "ERROR: Could not create GitHub Release ${TAG} after 3 attempts — tag exists, so this is an ORPHAN tag (SOC 2 CC7.2 gap)." >&2
    echo "       Recover with:" >&2
    echo "       gh release create ${TAG} --repo ${REPO} --title ${TAG} --notes \"\$(awk '/^## ${TAG} /{c=1;next} c&&/^## /{exit} c' RELEASE_NOTES.md)\"" >&2
    exit 1
  fi
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
DEPLOY_RESPONSE=$(gh_api -X POST -H "Accept: application/vnd.github+json" \
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

# Production release is org-native: the git tag created above fires .woodpecker/
# bake.yaml (repository_dispatch → infra TP baker), which bakes the gem-complete
# txn-scanner-app GCE image FROM txn-scanner-base. No container image tagging here.

# Pipeline-status notification (tag / release) is published to the ci-events
# Pub/Sub topic by the notify-status step (#780); Slack is deprecated, so no
# direct webhook call here.

echo "=== Release ${TAG} complete ==="
