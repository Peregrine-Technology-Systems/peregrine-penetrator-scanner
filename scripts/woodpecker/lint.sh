#!/usr/bin/env bash
set -euo pipefail

# Run RuboCop natively on the agent (ruby 4.0.5 via chruby + .ruby-version; no Docker)
BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

# Skip lint when code tree is identical to a target branch (promotion/sync-back).
# #944: tree-identity skip is only safe for promotion artifacts (see test.sh) —
# on a feature branch it was a green-by-deferral silent-OK. Feature branches lint.
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
    echo "==> Skipping lint: identical to ${TARGET} (already tested; promotion artifact)"
    exit 0
  fi
  CODE_CHANGES=$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | grep -cvE '\.(md|txt)$' || true)
  if [ "$CODE_CHANGES" = "0" ] && [ "$(git diff --name-only "origin/${TARGET}" HEAD 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "==> Skipping lint: only documentation files differ from ${TARGET}"
    exit 0
  fi
done

# Ruby is auto-selected by the agent via BASH_ENV (/etc/chruby-ci.sh runs
# `chruby "$(cat .ruby-version)"`); .ruby-version=4.0.5 → no explicit activation
# needed (infra #927, see test.sh). Echo for diagnostics.
echo "==> Ruby: $(ruby -v)"
# Exclude the development group (debug) — see test.sh: debug transitively pulls
# psych which builds from source and needs libyaml (absent on the agent).
# Exported so both `bundle install` and `bundle exec` honor it. (#945)
export BUNDLE_WITHOUT="development"
# shellcheck source=scripts/woodpecker/lib/git-dep-auth.sh
. "$(dirname "$0")/lib/git-dep-auth.sh"
bundle install --jobs 4 --retry 3
bundle exec rubocop --parallel
