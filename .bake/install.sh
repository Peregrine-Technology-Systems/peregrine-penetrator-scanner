#!/usr/bin/env bash
# Bake-time app install for the txn-scanner-app image (FROM txn-scanner-base).
# Runs AS ROOT, cwd=/opt/app (baker has copied the checkout here), BEFORE the
# baker's attack-surface scrub. Vendors the app's gems INTO the image — this is
# the bake, not runtime: the compiler is present here and is stripped afterward.
# Precompiled x86_64-linux gem variants are in Gemfile.lock, so no compile is
# expected; the bundle is placed into vendor/bundle and survives the scrub.
set -euo pipefail
bundle config set --local deployment true
bundle config set --local without 'development test'
bundle install --jobs 4
echo "[.bake/install] gems vendored: $(bundle list 2>/dev/null | grep -c '\*') gems"
