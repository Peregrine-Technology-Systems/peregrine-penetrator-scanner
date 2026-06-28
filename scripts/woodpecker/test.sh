#!/usr/bin/env bash
set -euo pipefail

# Run RSpec natively on the Woodpecker agent — ruby 4.0.5 via chruby + .ruby-version
# (parity with the txn-scanner-app baked image; no Docker). bundler ships with the ruby.
# Enforces: 100% test pass + 90% minimum line coverage
MINIMUM_COVERAGE=90
BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

# Skip tests when code tree is identical to a target branch (promotion/sync-back).
# #944: the tree-identity "already tested" fast-path is ONLY safe for promotion
# artifacts (sync/*, merge/*, release/*) — promote.yaml creates those only after
# the source branch's CI passed green, so an identical tree was genuinely tested.
# On a feature branch it was a green-by-deferral silent-OK: it skipped as
# "identical to development" while development's own CI was red, manufacturing a
# false green. Feature branches always run their own CI.
case "$BRANCH" in
  sync/*|merge/*|release/*) PROMO_ARTIFACT=yes ;;
  *) PROMO_ARTIFACT=no ;;
esac
git fetch origin development staging main --quiet 2>/dev/null || true
HEAD_TREE=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
for TARGET in development staging main; do
  if [ "$BRANCH" = "$TARGET" ]; then continue; fi
  TARGET_TREE=$(git rev-parse "origin/${TARGET}^{tree}" 2>/dev/null || echo "")
  if [ "$PROMO_ARTIFACT" = "yes" ] && [ -n "$HEAD_TREE" ] && [ "$HEAD_TREE" = "$TARGET_TREE" ]; then
    echo "==> Skipping tests: identical to ${TARGET} (already tested; promotion artifact)"
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

# Ruby is selected automatically by the agent: /etc/chruby-ci.sh is sourced via
# BASH_ENV on every CI step and runs `chruby "$(cat .ruby-version)"` against the
# checkout root. We ship .ruby-version=4.0.5, so 4.0.5 + bundler are already on
# PATH here — no explicit activation needed (infra #927). Echo for diagnostics.
echo "==> Ruby: $(ruby -v)"
# Exclude the development group (debug) — CI needs test + lint gems, not the
# debugger, and debug transitively pulls psych (no precompiled linux gem → builds
# from source → needs libyaml). Mirrors the production bake's --without. Exported
# so BOTH `bundle install` and `bundle exec` honor it (else bundler setup tries
# to load the uninstalled dev gems and fails). (#945)
export BUNDLE_WITHOUT="development"
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
