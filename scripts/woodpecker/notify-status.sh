#!/usr/bin/env bash
set -euo pipefail

# Post pipeline status to the ci-events Pub/Sub topic (bus-only-emit pattern,
# peregrine-infrastructure#1366). Slack is deprecated — CI agents no longer call a
# webhook directly. The monitoring droplet's forwarder subscribes to ci-events
# and routes pipeline.status events downstream. Mirrors
# peregrine-infrastructure/scripts/woodpecker/notify-status.sh (#780).
#
# Event type:  pipeline.status
# Attributes:  event_type, severity, repo
# Identity:    ci-agent@ci-runners-de (ambient on the GCP fleet agent)

REPO_FULL="${CI_REPO:-unknown}"
REPO="${REPO_FULL##*/}"
BRANCH="${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}"
COMMIT="${CI_COMMIT_SHA:0:7}"
FULL_SHA="${CI_COMMIT_SHA:-}"
AUTHOR="${CI_COMMIT_AUTHOR:-unknown}"
MESSAGE="${CI_COMMIT_MESSAGE:-no message}"
STATUS="${CI_PIPELINE_STATUS:-unknown}"
PIPELINE_URL="https://d3ci42.peregrinetechsys.net/repos/${CI_REPO_ID:-0}/pipeline/${CI_PIPELINE_NUMBER:-0}"
COMMIT_URL="https://github.com/${REPO_FULL}/commit/${FULL_SHA}"

# Truncate commit message to the first line
MESSAGE=$(echo "$MESSAGE" | head -1 | cut -c1-80)

VERSION=""
if [ "$STATUS" = "failure" ]; then
  SEVERITY="error"; EMOJI=":red_circle:"; COLOR="#dc3545"; TITLE="Pipeline FAILED"
elif [ "$BRANCH" = "main" ] && [ -f VERSION ]; then
  VERSION=$(cat VERSION | tr -d '[:space:]')
  SEVERITY="info"; EMOJI=":rocket:"; COLOR="#ffc107"; TITLE="PRODUCTION RELEASE v${VERSION}"
elif [ "$BRANCH" = "staging" ]; then
  SEVERITY="info"; EMOJI=":large_blue_circle:"; COLOR="#0d6efd"; TITLE="Staging passed"
elif [ "$BRANCH" = "development" ]; then
  SEVERITY="info"; EMOJI=":white_check_mark:"; COLOR="#28a745"; TITLE="Development passed"
else
  SEVERITY="info"; EMOJI=":white_check_mark:"; COLOR="#6c757d"; TITLE="CI passed (${BRANCH})"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build JSON via python3 — commit messages can contain quotes/backticks; sys.argv
# avoids shell-escaping gymnastics.
PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'event_type':   'pipeline.status',
    'timestamp':    sys.argv[1],
    'repo':         sys.argv[2],
    'repo_full':    sys.argv[3],
    'branch':       sys.argv[4],
    'commit':       sys.argv[5],
    'commit_url':   sys.argv[6],
    'author':       sys.argv[7],
    'message':      sys.argv[8],
    'status':       sys.argv[9],
    'severity':     sys.argv[10],
    'title':        sys.argv[11],
    'emoji':        sys.argv[12],
    'color':        sys.argv[13],
    'version':      sys.argv[14],
    'pipeline_url': sys.argv[15],
}))
" "$TIMESTAMP" "$REPO" "$REPO_FULL" "$BRANCH" "$COMMIT" "$COMMIT_URL" \
  "$AUTHOR" "$MESSAGE" "$STATUS" "$SEVERITY" "$TITLE" "$EMOJI" "$COLOR" \
  "$VERSION" "$PIPELINE_URL")

gcloud pubsub topics publish ci-events \
  --project=ci-runners-de \
  --message="$PAYLOAD" \
  --attribute="event_type=pipeline.status,severity=${SEVERITY},repo=${REPO}" \
  || echo "WARN: Pub/Sub publish failed — notification lost"
