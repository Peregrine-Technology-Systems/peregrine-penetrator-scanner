#!/usr/bin/env bash
set -euo pipefail

# Hybrid deploy:
#   development — no Docker, clone mode (handled by promote.yaml)
#   staging — trigger scan with baked image
#   main — tag scanner:staging as scanner:production (zero rebuild)

BRANCH="${CI_COMMIT_BRANCH:-}"
EVENT="${CI_PIPELINE_EVENT:-}"
REGISTRY="${DOCKER_REGISTRY:?DOCKER_REGISTRY not set}"

# #767: production triggers via GitHub Deployment API now (cross-repo rollout
# #1187), not legacy `branch: main` push. Map event=deployment to "main".
TARGET="$BRANCH"
if [ "$EVENT" = "deployment" ]; then
  TARGET="main"
fi

# #767: GitHub Deployment status callbacks for production deploys triggered
# via the Deployment API. Best-effort.
DEPLOYMENT_ID=""
GH_API="https://api.github.com"
GH_REPO="${CI_REPO:-Peregrine-Technology-Systems/peregrine-penetrator-scanner}"
if [ "$EVENT" = "deployment" ] && [ -n "${GH_TOKEN:-}" ]; then
  DEPLOY_REF="${CI_COMMIT_REF:-${CI_COMMIT_TAG:-${CI_COMMIT_SHA:-HEAD}}}"
  DEPLOY_REF="${DEPLOY_REF#refs/tags/}"
  DEPLOYMENT_ID=$(curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${GH_REPO}/deployments?ref=${DEPLOY_REF}&per_page=1" \
    2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || echo "")
  if [ -n "$DEPLOYMENT_ID" ] && [ "$DEPLOYMENT_ID" != "null" ]; then
    echo "Found Deployment id=${DEPLOYMENT_ID} for ref=${DEPLOY_REF}"
  else
    DEPLOYMENT_ID=""
  fi
fi

post_deployment_status() {
  [ -z "$DEPLOYMENT_ID" ] && return 0
  [ -z "${GH_TOKEN:-}" ] && return 0
  local state="$1" description="$2"
  curl -sS -o /dev/null -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${GH_REPO}/deployments/${DEPLOYMENT_ID}/statuses" \
    -d "$(jq -n --arg s "$state" --arg d "$description" '{state: $s, description: $d, environment: "production"}')" \
    || echo "Warning: Deployment status callback failed (state=$state)"
}

post_deployment_status "in_progress" "scanner deploy started"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then post_deployment_status "failure" "deploy.sh exited $rc"; fi' EXIT

case "$TARGET" in
  staging)
    echo "=== Triggering staging scan with baked image ==="
    scripts/woodpecker/trigger-scan.sh staging standard
    ;;
  main)
    echo "=== Promoting scanner:staging → scanner:production (by digest) ==="
    gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

    # Resolve staging digest — ensures exact bytes get promoted
    STAGING_DIGEST=$(gcloud artifacts docker images describe \
      "${REGISTRY}/scanner:staging" \
      --format='value(image_summary.digest)' 2>/dev/null || echo "")

    if [ -z "$STAGING_DIGEST" ]; then
      echo "ERROR: Could not resolve scanner:staging digest — aborting promotion"
      exit 1
    fi

    echo "Staging digest: ${STAGING_DIGEST}"
    gcloud artifacts docker tags add \
      "${REGISTRY}/scanner@${STAGING_DIGEST}" \
      "${REGISTRY}/scanner:production"
    echo "scanner:production → ${STAGING_DIGEST}"

    # Act → verify → alert: re-resolve scanner:production and assert it points at
    # the exact staging digest we just promoted. A retag that silently no-ops or
    # races another push would otherwise report success while production serves
    # the wrong bytes. The EXIT trap posts a failure Deployment status on exit 1.
    PROD_DIGEST=$(gcloud artifacts docker images describe \
      "${REGISTRY}/scanner:production" \
      --format='value(image_summary.digest)' 2>/dev/null || echo "")
    if [ "$PROD_DIGEST" != "$STAGING_DIGEST" ]; then
      echo "ERROR: production digest verification failed — scanner:production=${PROD_DIGEST:-<empty>} != staging=${STAGING_DIGEST}"
      exit 1
    fi
    echo "Verified: scanner:production digest == staging digest (${PROD_DIGEST})"
    ;;
  *)
    echo "No deployment for branch=$BRANCH event=$EVENT"
    ;;
esac

# #767: mark Deployment success and clear EXIT trap (no-op for non-deployment events)
post_deployment_status "success" "scanner deploy completed (target=$TARGET)"
trap - EXIT
