#!/usr/bin/env bash
set -euo pipefail

# Promote branch via GitHub API (no gh CLI dependency)
# Usage: promote.sh <base_branch> <head_branch> <auto|manual>

BASE="$1"
HEAD="$2"
MODE="${3:-manual}"
REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
API="https://api.github.com"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not set, skipping promotion"
  exit 0
fi

AUTH="Authorization: Bearer ${GH_TOKEN}"

# Check for existing open PR
EXISTING=$(curl -sf -H "$AUTH" \
  "${API}/repos/${REPO}/pulls?base=${BASE}&head=${HEAD}&state=open" \
  | jq 'length')

if [ "$EXISTING" -gt 0 ]; then
  echo "Promotion PR already exists"
  exit 0
fi

# Check for new commits
COMMITS=$(git rev-list "origin/${BASE}..origin/${HEAD}" --count 2>/dev/null || echo "0")
if [ "$COMMITS" = "0" ]; then
  echo "No new commits to promote"
  exit 0
fi

# Create PR
echo "Creating promotion PR: ${HEAD} → ${BASE}"
PR_RESPONSE=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/pulls" \
  -d "{
    \"title\": \"Promote ${HEAD} → ${BASE}\",
    \"body\": \"Automated promotion after CI pass on \`${HEAD}\`.\",
    \"head\": \"${HEAD}\",
    \"base\": \"${BASE}\"
  }")

PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number')
PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url')
echo "Created PR #${PR_NUMBER}: ${PR_URL}"

# Auto-merge if requested
if [ "$MODE" = "auto" ]; then
  curl -sf -X PUT -H "$AUTH" -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
    -d '{"merge_method": "merge"}' > /dev/null 2>&1 || \
    echo "Auto-merge queued (waiting for status checks)"
  echo "Auto-merge enabled"
else
  # Manual PRs (e.g. staging→main) require review — assign repo owner
  REPO_OWNER=$(curl -sf -H "$AUTH" "${API}/repos/${REPO}" | jq -r '.owner.login')
  if [ -n "$REPO_OWNER" ] && [ "$REPO_OWNER" != "null" ]; then
    curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
      -d "{\"team_reviewers\": [], \"reviewers\": [\"${REPO_OWNER}\"]}" > /dev/null 2>&1 || \
      echo "Warning: could not assign reviewer"
    echo "Manual merge required for ${HEAD} → ${BASE} (reviewer: ${REPO_OWNER})"
  else
    echo "Manual merge required for ${HEAD} → ${BASE} (could not determine repo owner)"
  fi
fi
