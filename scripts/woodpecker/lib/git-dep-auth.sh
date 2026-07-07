#!/usr/bin/env bash
# Authenticate bundler's fetch of the private peregrine_bus / peregrine_bus_gcp /
# peregrine_bus_nats gems from the Peregrine GitHub Packages registry (scanner#1106).
# Bundler resolves a `source "https://rubygems.pkg.github.com/..."` block via the
# host-only BUNDLE_RUBYGEMS__PKG__GITHUB__COM env var (shared read:packages PAT,
# secret `peregrine-packages-read` in project `ci-runners-de`) — no git
# credential-helper state, no credential written to Gemfile.lock (peregrine-bus
# CONSUMING.md; supersedes the old git-dep + gh_token insteadOf rewrite, scanner#1009).
#
# Source this before `bundle install`. No-op when gcloud/the secret is unavailable
# (e.g. local dev without GCP creds) — bundle install then fails loudly on 401/403
# rather than silently resolving against a stale credential.
if command -v gcloud >/dev/null 2>&1; then
  TOKEN=$(gcloud secrets versions access latest --secret=peregrine-packages-read --project=ci-runners-de 2>/dev/null || true)
  if [ -n "$TOKEN" ]; then
    export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="x-access-token:${TOKEN}"
  fi
fi
