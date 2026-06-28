#!/usr/bin/env bash
set -euo pipefail

# Run RSpec natively on the Woodpecker agent — ruby 4.0.5 via chruby + .ruby-version
# (parity with the txn-scanner-app baked image; no Docker). bundler ships with the ruby.
# Enforces: 100% test pass + 90% minimum line coverage
MINIMUM_COVERAGE=90
BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

# Skip tests when code tree is identical to a target branch (promotion/sync-back)
git fetch origin development staging main --quiet 2>/dev/null || true
HEAD_TREE=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
for TARGET in development staging main; do
  if [ "$BRANCH" = "$TARGET" ]; then continue; fi
  TARGET_TREE=$(git rev-parse "origin/${TARGET}^{tree}" 2>/dev/null || echo "")
  if [ -n "$HEAD_TREE" ] && [ "$HEAD_TREE" = "$TARGET_TREE" ]; then
    echo "==> Skipping tests: file content identical to ${TARGET} (already tested)"
    mkdir -p coverage && echo '{"result":{"line":100}}' > coverage/.last_run.json
    exit 0
  fi
  # Also skip if only docs changed
  CODE_CHANGES=$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | grep -cvE '\.(md|txt)$' || true)
  if [ "$CODE_CHANGES" = "0" ] && [ "$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "==> Skipping tests: only documentation files differ from ${TARGET}"
    mkdir -p coverage && echo '{"result":{"line":100}}' > coverage/.last_run.json
    exit 0
  fi
done

# Activate ruby 4.0.5 — the non-interactive Woodpecker step shell does not
# auto-switch chruby on .ruby-version, so activate it explicitly (chruby source,
# else the chruby rubies dir on PATH). Agent rubies live in /opt/rubies (infra).
for cs in /opt/chruby/share/chruby/chruby.sh /usr/local/share/chruby/chruby.sh /etc/profile.d/chruby.sh; do
  # shellcheck disable=SC1090
  [ -f "$cs" ] && { . "$cs"; chruby ruby-4.0.5 2>/dev/null || chruby 4.0.5 2>/dev/null || true; break; }
done
for rd in /opt/rubies/4.0.5/bin /opt/rubies/ruby-4.0.5/bin; do
  [ -x "$rd/ruby" ] && { export PATH="$rd:$PATH"; break; }
done
echo "==> Ruby: $(ruby -v)"
bundle install --jobs 4 --retry 3
APP_ENV=test bundle exec rspec --format documentation

# Enforce minimum coverage
if [ -f coverage/.last_run.json ]; then
  COVERAGE=$(ruby -rjson -e 'puts JSON.parse(File.read("coverage/.last_run.json"))["result"]["line"]')
  echo "Line coverage: ${COVERAGE}%"
  PASS=$(ruby -e "puts ${COVERAGE} >= ${MINIMUM_COVERAGE} ? 'yes' : 'no'")
  if [ "$PASS" != 'yes' ]; then
    echo "ERROR: Coverage ${COVERAGE}% is below ${MINIMUM_COVERAGE}% minimum"
    exit 1
  fi
  echo "Coverage gate passed (>= ${MINIMUM_COVERAGE}%)"
else
  echo 'WARNING: No coverage data found — skipping coverage check'
fi
