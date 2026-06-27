#!/usr/bin/env bash
# Trigger the infra keyless TP baker (peregrine-infrastructure .github/workflows/
# bake-tp.yml) to bake txn-scanner-app FROM txn-scanner-base at the given ref.
# Requires GH_TOKEN (peregrine-ci-app installation token w/ actions:write on the
# infra repo) — minted by the caller via get-gh-app-installation-token.sh.
# Scanner stays 100% Woodpecker + zero org access: this is a GitHub API call.
set -euo pipefail
: "${GH_TOKEN:?GH_TOKEN not set (mint the peregrine-ci-app token first)}"
REF="${1:-${CI_COMMIT_TAG:-}}"
: "${REF:?bake-dispatch needs a scanner ref (arg1 or CI_COMMIT_TAG)}"

INFRA_REPO="Peregrine-Technology-Systems/peregrine-infrastructure"
SCANNER_REPO="Peregrine-Technology-Systems/peregrine-penetrator-scanner"

echo "Dispatching txn-scanner-app bake @ ${REF} -> ${INFRA_REPO} bake-tp.yml"
curl -fsS -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${INFRA_REPO}/actions/workflows/bake-tp.yml/dispatches" \
  -d "$(jq -nc --arg ref "${REF}" --arg repo "${SCANNER_REPO}" \
        '{ref:"main", inputs:{tp:"txn-scanner", tp_repo:$repo, ref:$ref}}')"
echo "Bake dispatched for txn-scanner @ ${REF}."
