#!/usr/bin/env bash
set -euo pipefail

# Apply Pattern A branch protection to development, staging, and main.
#
# Pattern A ("billing pattern" — the canonical Peregrine default):
#   - required_status_checks: null  (no required CI contexts — avoids the
#     required-check-vs-excluded-branch deadlock that wedges sync-back PRs)
#   - required_pull_request_reviews: 0 approvals, but a PR IS required
#     (this is what prevents direct pushes)
#   - enforce_admins: true          (admins are also bound by the PR requirement)
#
# Release-path compatibility: with enforce_admins=true, NOTHING may push
# directly to a protected branch — including version-bump.sh. That script is
# therefore written to commit on a release/* branch, open + API-merge a PR to
# main, and create the tag via the GitHub API. promote.sh and sync-back.sh
# already use branch+PR. Do NOT enable enforce_admins on main until the
# PR-based version-bump.sh has landed on main, or the next release wedges.
#
# This script is the source-of-truth artifact for the repo's branch protection
# (falcon discipline: shared state must be reproducible from source). Re-run it
# to reconcile drift; it is idempotent.
#
# Usage: scripts/setup-branch-protection.sh [development|staging|main ...]
#   No args → all three branches.

REPO="${REPO:-Peregrine-Technology-Systems/peregrine-penetrator-scanner}"
BRANCHES=("$@")
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  BRANCHES=(development staging main)
fi

apply() {
  local branch="$1"
  echo "=== Applying Pattern A to ${branch} ==="
  gh api -X PUT "repos/${REPO}/branches/${branch}/protection" \
    --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  echo "  ✓ ${branch}: PR required, 0 approvals, enforce_admins=true, no required checks"
}

for b in "${BRANCHES[@]}"; do
  apply "$b"
done

echo "Done. Verify with: gh api repos/${REPO}/branches/<branch>/protection"
