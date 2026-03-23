#!/usr/bin/env bash
set -euo pipefail

# Branch promotion via GitHub REST API (no gh CLI dependency)
# development → staging: auto-merge
# staging → main: manual review

REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"
ORG="Peregrine-Technology-Systems"
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

# Check for existing open PR
EXISTING=$(curl -s -H "$AUTH" \
  "${API}/repos/${REPO}/pulls?base=${BASE}&head=${ORG}:${BRANCH}&state=open" \
  | jq 'length // 0')

if [ "$EXISTING" -gt 0 ]; then
  echo "Promotion PR already exists (${BRANCH} → ${BASE})"
  exit 0
fi

# Check for new commits via GitHub API (git rev-list fails in Woodpecker's shallow clone)
COMPARE=$(curl -s -H "$AUTH" "${API}/repos/${REPO}/compare/${BASE}...${BRANCH}" | jq -r '.ahead_by // 0')
if [ "$COMPARE" = "0" ]; then
  echo "No new commits to promote (${BRANCH} is up to date with ${BASE})"
  exit 0
fi
COMMITS="$COMPARE"

# Create PR
echo "Creating promotion PR: ${BRANCH} → ${BASE} (${COMMITS} commits)"
PR_RESPONSE=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "${API}/repos/${REPO}/pulls" \
  -d "{
    \"title\": \"Promote ${BRANCH} → ${BASE}\",
    \"body\": \"Automated promotion after CI pass on \`${BRANCH}\`.\",
    \"head\": \"${BRANCH}\",
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

if [ "$MODE" = "auto" ]; then
  MERGE_RESULT=$(curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge" \
    -d '{"merge_method": "merge"}')
  if echo "$MERGE_RESULT" | jq -e '.merged' > /dev/null 2>&1; then
    echo "Auto-merged successfully"
  else
    echo "Auto-merge queued or waiting for status checks"
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
