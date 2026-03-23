#!/usr/bin/env bash
set -euo pipefail

# Post pipeline failure notification to Slack
# Uses Woodpecker CI environment variables

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL not set, skipping notification"
  exit 0
fi

REPO="${CI_REPO:-unknown}"
BRANCH="${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}"
COMMIT="${CI_COMMIT_SHA:0:7}"
AUTHOR="${CI_COMMIT_AUTHOR:-unknown}"
MESSAGE="${CI_COMMIT_MESSAGE:-no message}"
WOODPECKER_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"

MESSAGE=$(echo "$MESSAGE" | head -1 | cut -c1-80)

curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"text\": \":red_circle: Pipeline failed\",
    \"blocks\": [
      {
        \"type\": \"section\",
        \"text\": {
          \"type\": \"mrkdwn\",
          \"text\": \":red_circle: *Pipeline failed* — <${WOODPECKER_URL}|View in Woodpecker>\n*Repo:* ${REPO}\n*Branch:* ${BRANCH}\n*Commit:* \`${COMMIT}\` — ${MESSAGE}\n*Author:* ${AUTHOR}\"
        }
      }
    ]
  }" || echo "Warning: Slack notification failed"
