#!/usr/bin/env bash
set -euo pipefail

# Run RuboCop inside Docker (agent-independent — no Ruby required on host)
BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

# Skip lint when code tree is identical to a target branch (promotion/sync-back)
git fetch origin development staging main --quiet 2>/dev/null || true
HEAD_TREE=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
for TARGET in development staging main; do
  if [ "$BRANCH" = "$TARGET" ]; then continue; fi
  TARGET_TREE=$(git rev-parse "origin/${TARGET}^{tree}" 2>/dev/null || echo "")
  if [ -n "$HEAD_TREE" ] && [ "$HEAD_TREE" = "$TARGET_TREE" ]; then
    echo "==> Skipping lint: file content identical to ${TARGET} (already tested)"
    exit 0
  fi
  CODE_CHANGES=$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | grep -cvE '\.(md|txt)$' || true)
  if [ "$CODE_CHANGES" = "0" ] && [ "$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "==> Skipping lint: only documentation files differ from ${TARGET}"
    exit 0
  fi
done

docker run --rm \
  -v "$CI_WORKSPACE":/app -w /app \
  ruby:3.2.2 bash -c "
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq libsqlite3-dev > /dev/null 2>&1
    bundle install --jobs 4 --retry 3 --path vendor/bundle
    bundle exec rubocop --parallel
  "
