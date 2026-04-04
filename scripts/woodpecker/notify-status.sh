#!/usr/bin/env bash
set -euo pipefail

# Post pipeline status to Slack — runs on EVERY build
# Highlights: failures (red), success (green/blue per environment)

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL not set, skipping notification"
  exit 0
fi

REPO_FULL="${CI_REPO:-unknown}"
REPO="${REPO_FULL##*/}"  # Strip org prefix — just the repo name
BRANCH="${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}"
COMMIT="${CI_COMMIT_SHA:0:7}"
FULL_SHA="${CI_COMMIT_SHA:-}"
AUTHOR="${CI_COMMIT_AUTHOR:-unknown}"
MESSAGE="${CI_COMMIT_MESSAGE:-no message}"
STATUS="${CI_PIPELINE_STATUS:-unknown}"
WOODPECKER_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"
COMMIT_URL="https://github.com/${REPO_FULL}/commit/${FULL_SHA}"
REPO_URL="https://github.com/${REPO_FULL}"

# Truncate commit message to first line
MESSAGE=$(echo "$MESSAGE" | head -1 | cut -c1-80)

# Determine notification style — failure first, then environment-specific success
if [ "$STATUS" = "failure" ]; then
  EMOJI=":red_circle:"
  COLOR="#dc3545"
  TITLE="Pipeline FAILED"
elif [ "$BRANCH" = "main" ] && [ -f VERSION ]; then
  VERSION=$(cat VERSION | tr -d '[:space:]')
  EMOJI=":white_check_mark:"
  COLOR="#28a745"
  TITLE="Main passed (v${VERSION})"
elif [ "$BRANCH" = "staging" ]; then
  EMOJI=":large_blue_circle:"
  COLOR="#0d6efd"
  TITLE="Staging passed"
elif [ "$BRANCH" = "development" ]; then
  EMOJI=":white_check_mark:"
  COLOR="#28a745"
  TITLE="Development passed"
else
  # Feature branches
  EMOJI=":white_check_mark:"
  COLOR="#6c757d"
  TITLE="CI passed (${BRANCH})"
fi

# Build the message — repo name linked, no org prefix
DETAILS="*Branch:* ${BRANCH}\n*Commit:* <${COMMIT_URL}|\`${COMMIT}\`> — ${MESSAGE}\n*Author:* ${AUTHOR}"

# Standard notification for all builds (production celebration moved to deploy pipeline #367)
curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"text\": \"${EMOJI} ${TITLE} — ${REPO}\",
    \"attachments\": [
      {
        \"color\": \"${COLOR}\",
        \"blocks\": [
          {
            \"type\": \"section\",
            \"text\": {
              \"type\": \"mrkdwn\",
              \"text\": \"${EMOJI} *${TITLE}* *<${REPO_URL}|${REPO}>*\n${DETAILS}\n<${WOODPECKER_URL}|View pipeline>\"
            }
          }
        ]
      }
    ]
  }" || echo "Warning: Slack notification failed"
