#!/usr/bin/env bash
set -euo pipefail

# Sync RELEASE_NOTES.md + VERSION from tagged release back to development and staging
# Triggered by: tag event (v*)
# Uses local merge branch (same pattern as promote.sh) to avoid GitHub merge conflicts
# Ruby: syncs VERSION file instead of package.json

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
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"

# Full history needed for merge
git fetch --unshallow origin 2>/dev/null || true

for BRANCH in development staging; do
  MERGE_BRANCH="sync/version-${VERSION}-to-${BRANCH}"

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

  git fetch origin "$BRANCH" main

  # Create merge branch from target, merge main
  git checkout -b "$MERGE_BRANCH" "origin/${BRANCH}"

  if git merge "origin/main" --no-edit 2>/dev/null; then
    echo "Merge succeeded cleanly"
  else
    # Auto-resolve RELEASE_NOTES.md — keep main's version headers, target's Unreleased
    if git diff --name-only --diff-filter=U | grep -q 'RELEASE_NOTES.md'; then
      echo "Auto-resolving RELEASE_NOTES.md"
      git checkout "origin/main" -- RELEASE_NOTES.md
      git add RELEASE_NOTES.md
    fi

    REMAINING=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -n "$REMAINING" ]; then
      echo "ERROR: Unresolvable conflicts in: ${REMAINING}"
      git merge --abort
      git checkout "${CI_COMMIT_SHA}" 2>/dev/null || git checkout HEAD
      continue
    fi

    git commit --no-edit
  fi

  # Ensure exactly one ## Unreleased header
  if ! grep -q '^## Unreleased$' RELEASE_NOTES.md; then
    perl -i -pe 'print "## Unreleased\n\n" if /^## v/ && !$done++' RELEASE_NOTES.md
  fi

  # Dedup any duplicate headers
  awk '!seen[$0]++ || !/^## /' RELEASE_NOTES.md > RELEASE_NOTES.tmp && mv RELEASE_NOTES.tmp RELEASE_NOTES.md

  # Check if dedup changed anything
  if ! git diff --quiet RELEASE_NOTES.md; then
    git add RELEASE_NOTES.md
    git commit --amend --no-edit
  fi

  # Skip if no actual file changes vs target
  DIFF_FILES=$(git diff --name-only "origin/${BRANCH}" HEAD 2>/dev/null || true)
  if [ -z "$DIFF_FILES" ]; then
    echo "No file changes after merge — skipping"
    git checkout "${CI_COMMIT_SHA}" 2>/dev/null || git checkout HEAD
    git branch -D "$MERGE_BRANCH" 2>/dev/null || true
    continue
  fi

  git push origin "$MERGE_BRANCH"

  PR_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/pulls" \
    -d "{
      \"title\": \"Sync: ${VERSION} version files to ${BRANCH}\",
      \"body\": \"Auto-sync version files from production release ${VERSION}.\",
      \"head\": \"${MERGE_BRANCH}\",
      \"base\": \"${BRANCH}\"
    }")

  PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number // empty')
  if [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ]; then
    PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url')
    echo "Created sync PR #${PR_NUMBER}: ${PR_URL}"

    # Auto-merge
    MERGE_RESULT=$(curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
      -d '{"merge_method": "merge"}')
    if echo "$MERGE_RESULT" | jq -e '.merged' > /dev/null 2>&1; then
      echo "Auto-merged successfully"
      # Clean up merge branch
      curl -s -X DELETE -H "$AUTH" \
        "${API}/repos/${REPO}/git/refs/heads/${MERGE_BRANCH}" > /dev/null 2>&1 || true
    else
      echo "Auto-merge queued or waiting for status checks"
    fi
  else
    echo "Failed to create sync PR to ${BRANCH}"
    echo "$PR_RESPONSE" | jq -r '.message // .' 2>/dev/null || true
  fi

  git checkout "${CI_COMMIT_SHA}" 2>/dev/null || git checkout HEAD
done
