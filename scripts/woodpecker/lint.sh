#!/usr/bin/env bash
set -euo pipefail

# Run RuboCop natively on the agent (ruby 4.0.5 via chruby + .ruby-version; no Docker)
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

# Activate ruby 4.0.5 (see test.sh — the step shell doesn't auto-switch chruby).
for cs in /opt/chruby/share/chruby/chruby.sh /usr/local/share/chruby/chruby.sh /etc/profile.d/chruby.sh; do
  # shellcheck disable=SC1090
  [ -f "$cs" ] && { . "$cs"; chruby ruby-4.0.5 2>/dev/null || chruby 4.0.5 2>/dev/null || true; break; }
done
for rd in /opt/rubies/4.0.5/bin /opt/rubies/ruby-4.0.5/bin; do
  [ -x "$rd/ruby" ] && { export PATH="$rd:$PATH"; break; }
done
echo "==> Ruby: $(ruby -v)"
bundle install --jobs 4 --retry 3
bundle exec rubocop --parallel
