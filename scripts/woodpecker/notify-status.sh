#!/usr/bin/env bash
set -euo pipefail

# Post pipeline status to Slack — runs on EVERY build
# Highlights: failures (red), production promotions (gold with version), success (green)

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL not set, skipping notification"
  exit 0
fi

REPO="${CI_REPO:-unknown}"
BRANCH="${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}"
COMMIT="${CI_COMMIT_SHA:0:7}"
FULL_SHA="${CI_COMMIT_SHA:-}"
AUTHOR="${CI_COMMIT_AUTHOR:-unknown}"
MESSAGE="${CI_COMMIT_MESSAGE:-no message}"
STATUS="${CI_PIPELINE_STATUS:-unknown}"
WOODPECKER_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"
COMMIT_URL="https://github.com/${REPO}/commit/${FULL_SHA}"

# Truncate commit message to first line
MESSAGE=$(echo "$MESSAGE" | head -1 | cut -c1-80)

# Determine notification style
if [ "$STATUS" = "failure" ]; then
  EMOJI=":red_circle:"
  COLOR="#dc3545"
  TITLE="Pipeline FAILED"
elif [ "$BRANCH" = "main" ] && [ -f VERSION ]; then
  VERSION=$(cat VERSION | tr -d '[:space:]')
  EMOJI=":rocket::rocket::rocket:"
  COLOR="#ffc107"
  TITLE="PRODUCTION RELEASE v${VERSION}"
elif [ "$BRANCH" = "staging" ]; then
  EMOJI=":large_blue_circle:"
  COLOR="#0d6efd"
  TITLE="Staging build"
else
  EMOJI=":white_check_mark:"
  COLOR="#28a745"
  TITLE="Pipeline passed"
fi

# Build the message
DETAILS="*Repo:* ${REPO}\n*Branch:* ${BRANCH}\n*Commit:* <${COMMIT_URL}|\`${COMMIT}\`> — ${MESSAGE}\n*Author:* ${AUTHOR}"

# Production releases get extra emphasis
if [ "$BRANCH" = "main" ] && [ -f VERSION ]; then
  VERSION=$(cat VERSION | tr -d '[:space:]')
  DETAILS="*Repo:* ${REPO}\n*Version:* \`v${VERSION}\`\n*Commit:* <${COMMIT_URL}|\`${COMMIT}\`> — ${MESSAGE}\n*Author:* ${AUTHOR}\n*Status:* Deployed to production"
fi

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
              \"text\": \"${EMOJI} *${TITLE}* — <${WOODPECKER_URL}|View pipeline>\n${DETAILS}\"
            }
          }
        ]
      }
    ]
  }" || echo "Warning: Slack notification failed"
