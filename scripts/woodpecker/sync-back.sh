#!/usr/bin/env bash
set -euo pipefail

# Sync RELEASE_NOTES.md from tagged release back to development and staging
# Triggered by: tag event (v*)

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"
VERSION="${CI_COMMIT_TAG}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping sync-back"
  exit 0
fi

if [ -z "${VERSION:-}" ]; then
  echo "No tag found, skipping sync-back"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

git config user.name "woodpecker-ci[bot]"
git config user.email "woodpecker-ci[bot]@users.noreply.github.com"

# Set push URL with token (Woodpecker clone uses HTTPS without push credentials)
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"

for BRANCH in development staging; do
  SYNC_BRANCH="sync/version-${VERSION}-to-${BRANCH}"

  echo ""
  echo "=== Syncing to ${BRANCH} ==="

  # Check for existing sync PR
  EXISTING=$(curl -s -H "$AUTH" \
    "${API}/repos/${REPO}/pulls?state=open&base=${BRANCH}" \
    | jq "[.[] | select(.title | contains(\"${VERSION}\"))] | length")

  if [ "$EXISTING" -gt 0 ]; then
    echo "Sync PR to ${BRANCH} already exists — skipping"
    continue
  fi

  git fetch origin "$BRANCH"
  git checkout -b "$SYNC_BRANCH" "origin/${BRANCH}"

  # Copy RELEASE_NOTES.md from the tagged commit (authoritative source)
  git checkout "${CI_COMMIT_SHA}" -- RELEASE_NOTES.md

  # Re-insert ## Unreleased header (main doesn't have it)
  perl -i -pe 'print "## Unreleased\n\n" if /^## v/ && !$done++' RELEASE_NOTES.md

  if ! grep -q '^## Unreleased$' RELEASE_NOTES.md; then
    perl -i -pe 's/^(# Release Notes)$/$1\n\n## Unreleased/' RELEASE_NOTES.md
  fi

  # Deduplicate version headings (merge=union can create duplicates)
  awk '!seen[$0]++ || !/^## v[0-9]/' RELEASE_NOTES.md > RELEASE_NOTES.md.tmp \
    && mv RELEASE_NOTES.md.tmp RELEASE_NOTES.md

  # Remove any stale entries between ## Unreleased and the first ## v heading
  # (these are entries that shipped in this release but linger from the branch's old Unreleased)
  perl -0777 -i -pe 's/(## Unreleased)\n\n(?:- .*\n)*\n(## v)/$1\n\n$2/s' RELEASE_NOTES.md

  git add RELEASE_NOTES.md

  if git diff --cached --quiet && git diff --quiet; then
    echo "No changes to sync to ${BRANCH} — skipping"
    git checkout "${CI_COMMIT_SHA}"
    git branch -D "$SYNC_BRANCH"
    continue
  fi

  git commit -m "Sync: Update version to ${VERSION} from production release

Co-Authored-By: woodpecker-ci[bot] <woodpecker-ci[bot]@users.noreply.github.com>"

  git push origin "$SYNC_BRANCH"

  PR_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/pulls" \
    -d "{
      \"title\": \"Sync: ${VERSION} version files to ${BRANCH}\",
      \"body\": \"Auto-sync version files from production release ${VERSION}.\",
      \"head\": \"${SYNC_BRANCH}\",
      \"base\": \"${BRANCH}\"
    }")

  PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number // empty')
  if [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ]; then
    PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url')
    echo "Created sync PR #${PR_NUMBER}: ${PR_URL}"

    curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
      -d '{"merge_method": "merge"}' > /dev/null 2>&1 || true
    echo "Auto-merge requested for ${BRANCH} sync PR"
  else
    echo "Failed to create sync PR to ${BRANCH}"
    echo "$PR_RESPONSE" | jq -r '.message // .' 2>/dev/null || true
  fi

  git checkout "${CI_COMMIT_SHA}" 2>/dev/null || git checkout HEAD
done
