#!/usr/bin/env bash
set -euo pipefail

# Run RuboCop inside Docker (agent-independent — no Ruby required on host)
docker run --rm \
  -v "$CI_WORKSPACE":/app -w /app \
  ruby:3.2.2 bash -c "
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq libsqlite3-dev > /dev/null 2>&1
    bundle install --jobs 4 --retry 3 --path vendor/bundle
    bundle exec rubocop --parallel
  "
