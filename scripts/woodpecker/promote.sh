#!/usr/bin/env bash
set -euo pipefail

# Branch promotion via local merge branch
# Always merges locally (respects .gitattributes merge=union for RELEASE_NOTES)
# then pushes merge branch and creates PR
#
# development → staging: auto-merge
# staging → main: manual review

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"
BRANCH="${CI_COMMIT_BRANCH}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping promotion"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Determine promotion target
case "$BRANCH" in
  development) BASE="staging";  MODE="auto" ;;
  staging)     BASE="main";     MODE="manual" ;;
  *)           echo "No promotion for branch: $BRANCH"; exit 0 ;;
esac

# ── Guard: skip if this push is itself a sync-back or release commit ──
COMMIT_MSG="${CI_COMMIT_MESSAGE:-}"
if echo "$COMMIT_MSG" | grep -qiE '^Sync:'; then
  echo "Skipping promotion — triggered by sync-back commit"
  exit 0
fi
if echo "$COMMIT_MSG" | grep -qE '^release: v[0-9]'; then
  echo "Skipping promotion — triggered by release commit"
  exit 0
fi

# ── Guard: skip if sync-back or release PRs target our base branch ──
INFLIGHT=$(curl -s -H "$AUTH" \
  "${API}/repos/${REPO}/pulls?state=open&base=${BASE}&per_page=100" \
  | jq '[.[] | select(
      (.title | test("^Sync:"))
      or (.head.ref | test("^release/"))
    )] | length')

if [ "$INFLIGHT" -gt 0 ]; then
  echo "Skipping promotion — ${INFLIGHT} sync-back or release PR(s) targeting ${BASE}"
  exit 0
fi

# ── Guard: skip if promotion PR already exists ──
MERGE_BRANCH="merge/${BRANCH}-to-${BASE}"
EXISTING=$(curl -s -H "$AUTH" \
  "${API}/repos/${REPO}/pulls?base=${BASE}&state=open" \
  | jq "[.[] | select(
      (.head.ref == \"${BRANCH}\")
      or (.head.ref == \"${MERGE_BRANCH}\")
    )] | length")

if [ "$EXISTING" -gt 0 ]; then
  echo "Promotion PR already exists (${BRANCH} → ${BASE})"
  exit 0
fi

# ── Guard: skip if no new commits ──
COMPARE=$(curl -s -H "$AUTH" "${API}/repos/${REPO}/compare/${BASE}...${BRANCH}" | jq -r '.ahead_by // 0')
if [ "$COMPARE" = "0" ]; then
  echo "No new commits to promote (${BRANCH} is up to date with ${BASE})"
  exit 0
fi

echo "Promoting ${BRANCH} → ${BASE} (${COMPARE} commits)"

# ── Create local merge branch ──
git config user.name "woodpecker-ci[bot]"
git config user.email "woodpecker-ci[bot]@users.noreply.github.com"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"

git fetch --unshallow origin 2>/dev/null || true
git fetch origin "$BRANCH" "$BASE"
# Delete stale remote merge branch if one was left behind by a manually-closed
# prior promote PR — otherwise the push below fails non-fast-forward.
# (Incident 2026-04-21 across scaler/front-end/etc.)
git push origin --delete "$MERGE_BRANCH" 2>/dev/null || true

git checkout -b "$MERGE_BRANCH" "origin/${BASE}"

if git merge "origin/${BRANCH}" --no-edit 2>/dev/null; then
  echo "Merge succeeded cleanly"
  # Skip if merge produced no file changes (trees identical despite commit count)
  if [ "$(git rev-parse HEAD^{tree})" = "$(git rev-parse "origin/${BASE}^{tree}")" ]; then
    echo "No file changes after merge — trees identical, skipping promotion"
    exit 0
  fi
else
  # Auto-resolve RELEASE_NOTES.md — keep source branch version
  if git diff --name-only --diff-filter=U | grep -q 'RELEASE_NOTES.md'; then
    echo "Auto-resolving RELEASE_NOTES.md — keeping ${BRANCH} content"
    git checkout "origin/${BRANCH}" -- RELEASE_NOTES.md
    git add RELEASE_NOTES.md
  fi

  # Fail on any remaining conflicts
  REMAINING=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$REMAINING" ]; then
    echo "ERROR: Unresolvable conflicts in: ${REMAINING}"
    git merge --abort
    exit 1
  fi

  git commit --no-edit
fi

# Dedup ## Unreleased headers (safety net for merge=union artifacts)
if [ -f RELEASE_NOTES.md ]; then
  DUPES=$(grep -c '^## Unreleased$' RELEASE_NOTES.md || true)
  if [ "$DUPES" -gt 1 ]; then
    awk '!seen[$0]++ || !/^## Unreleased$/' RELEASE_NOTES.md > RELEASE_NOTES.tmp && mv RELEASE_NOTES.tmp RELEASE_NOTES.md
    git add RELEASE_NOTES.md
    # Separate chore: commit — NEVER amend (global CLAUDE.md Rule #9 + the
    # ROBUST_PROMOTE_PATTERN.md warning; the squash-free merge keeps it readable).
    git commit -m "chore: dedup ## Unreleased headers (merge=union artifact)"
  fi
fi

# Pass 2: strip stale Unreleased entries already present in a versioned section
# (#842, Rule #13). merge=union leaves entries under ## Unreleased on source
# branches after version-bump moved them into ## vX on main; left unchecked they
# collapse into the wrong section → empty Unreleased → no tag (the "#1 cause of
# stuck releases"). Called UNCONDITIONALLY (no `command -v` guard): if the script
# can't run, the pipeline fails loud rather than silently skipping the cleanup.
# Pass 3 (repair misfiled) is deliberately NOT adopted — this repo has done
# retroactive RELEASE_NOTES edits, which Pass 3's reference notes flag as a sharp
# edge; Pass 2 + version-bump's empty-Unreleased drift-fail is correct here.
if [ -f RELEASE_NOTES.md ]; then
  scripts/cleanup-stale-unreleased.sh RELEASE_NOTES.md
  if ! git diff --quiet RELEASE_NOTES.md; then
    git add RELEASE_NOTES.md
    git commit -m "chore: strip stale Unreleased entries already released (#842)"
  fi
fi

git push origin "$MERGE_BRANCH"

# ── Create PR ──
PR_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/pulls" \
  -d "{
    \"title\": \"Promote ${BRANCH} → ${BASE}\",
    \"body\": \"Automated promotion after CI pass on \`${BRANCH}\`.\",
    \"head\": \"${MERGE_BRANCH}\",
    \"base\": \"${BASE}\"
  }")

PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number // empty')
if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
  echo "Failed to create PR:"
  echo "$PR_RESPONSE" | jq -r '.message // .errors // .' 2>/dev/null || echo "$PR_RESPONSE"
  exit 1
fi

PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url')
echo "Created PR #${PR_NUMBER}: ${PR_URL}"

# ── Auto-merge or request reviewer ──
if [ "$MODE" = "auto" ]; then
  # GitHub evaluates mergeability asynchronously — a PUT /merge on a brand-new PR
  # returns 405/409 until the check resolves. Poll for it to settle, then merge
  # with retry, then FAIL LOUD if it never lands. The old single-shot PUT printed
  # "queued or waiting" and exit-0'd on failure — a silent-OK that left PRs open
  # with no clear error and needed manual --admin merges (#775). Canonical poll +
  # retry from ROBUST_PROMOTE_PATTERN.md. Accept clean|unstable (a non-required
  # check pending/failing never blocks the merge); blocked/dirty/behind keep
  # polling. The merge-branch flow is idempotent, so a failed run re-runs cleanly.
  echo "Waiting for PR #${PR_NUMBER} to become mergeable..."
  for i in $(seq 1 6); do
    MERGE_STATE=$(curl -s -H "$AUTH" "${API}/repos/${REPO}/pulls/${PR_NUMBER}" \
      | jq -r '.mergeable_state // "unknown"')
    if [ "$MERGE_STATE" = "clean" ] || [ "$MERGE_STATE" = "unstable" ]; then break; fi
    echo "  mergeability: ${MERGE_STATE} — retrying in 5s (attempt ${i}/6)"
    sleep 5
  done

  MERGED=false
  for ATTEMPT in 1 2 3; do
    MERGE_RESULT=$(curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
      -d '{"merge_method": "merge"}')
    if echo "$MERGE_RESULT" | jq -e '.merged' > /dev/null 2>&1; then
      MERGED=true
      echo "Auto-merged successfully"
      curl -s -X DELETE -H "$AUTH" \
        "${API}/repos/${REPO}/git/refs/heads/${MERGE_BRANCH}" > /dev/null 2>&1 || true
      break
    fi
    echo "Merge attempt ${ATTEMPT}/3 failed: $(echo "$MERGE_RESULT" | jq -r '.message // "?"')"
    [ "$ATTEMPT" -lt 3 ] && sleep 5
  done

  if [ "$MERGED" = "false" ]; then
    echo "ERROR: auto-merge failed after 3 attempts — PR #${PR_NUMBER} left open"
    exit 1
  fi
else
  REPO_OWNER=$(curl -s -H "$AUTH" "${API}/repos/${REPO}" | jq -r '.owner.login // empty')
  if [ -n "$REPO_OWNER" ] && [ "$REPO_OWNER" != "null" ]; then
    curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
      -d "{\"team_reviewers\": [], \"reviewers\": [\"${REPO_OWNER}\"]}" > /dev/null 2>&1 || true
    echo "Manual merge required for ${BRANCH} → ${BASE} (reviewer: ${REPO_OWNER})"
  else
    echo "Manual merge required for ${BRANCH} → ${BASE}"
  fi
fi
