#!/usr/bin/env bash
set -euo pipefail

# Deploy step — trigger scans per environment
# No Docker image tagging needed — scan VMs clone app code at the branch directly

BRANCH="${CI_COMMIT_BRANCH}"

case "$BRANCH" in
  development)
    echo "Development — promotion handled by promote.yaml"
    ;;
  staging)
    echo "=== Triggering staging scan ==="
    scripts/woodpecker/trigger-scan.sh staging standard
    ;;
  main)
    echo "Production — scans triggered manually or via scheduler"
    ;;
  *)
    echo "No deployment for branch: $BRANCH"
    ;;
esac
