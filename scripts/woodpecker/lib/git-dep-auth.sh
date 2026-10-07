#!/usr/bin/env bash
# Authenticate bundler's fetch of the private peregrine_bus / peregrine_bus_gcp /
# peregrine_bus_nats gems from the Peregrine GitHub Packages registry (scanner#1106).
# Bundler resolves a `source "https://rubygems.pkg.github.com/..."` block via the
# host-only BUNDLE_RUBYGEMS__PKG__GITHUB__COM env var (shared read:packages PAT,
# secret `peregrine-packages-read`) — no git credential-helper state, no credential
# written to Gemfile.lock (peregrine-bus CONSUMING.md; scanner#1009).
#
# Token source, in order (#1206 — the old read targeted the decommissioned
# ci-runners-de project and swallowed the error, so CI died later in bundler with
# a misleading "Authentication is required"):
#   1. GH_PACKAGES_TOKEN — exported on every step by the CI agent hook.
#   2. Secret Manager in PACKAGES_READ_PROJECT (default peregrine-production).
# No token: fail loud in CI; warn-only for local dev (bundler then 401s itself).
#
# Sourced before `bundle install` — uses `return`, never `exit`.
_pkg_project="${PACKAGES_READ_PROJECT:-peregrine-production}"
_pkg_token="${GH_PACKAGES_TOKEN:-}"
if [ -z "$_pkg_token" ] && command -v gcloud >/dev/null 2>&1; then
  _pkg_token=$(gcloud secrets versions access latest --secret=peregrine-packages-read \
    --project="$_pkg_project") || _pkg_token=""
fi

if [ -n "$_pkg_token" ]; then
  export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="x-access-token:${_pkg_token}"
elif [ -n "${CI:-}" ]; then
  echo "ERROR: no GitHub Packages token — GH_PACKAGES_TOKEN unset and secret" \
    "peregrine-packages-read unreadable in project ${_pkg_project} (#1206)" >&2
  unset _pkg_project _pkg_token
  return 1
else
  echo "WARN: no GitHub Packages token (GH_PACKAGES_TOKEN unset, peregrine-packages-read" \
    "unreadable in ${_pkg_project}); private gems will fail to install" >&2
fi
unset _pkg_project _pkg_token
