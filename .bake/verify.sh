#!/usr/bin/env bash
# Post-scrub sanity for txn-scanner-app. Runs AFTER the baker strips build tools.
# Asserts the runtime is intact and gems are placed — NEVER installs.
set -euo pipefail
command -v ruby   >/dev/null || { echo "FAIL: ruby not on PATH"; exit 1; }
test -f bin/scan          || { echo "FAIL: bin/scan missing"; exit 1; }
bundle check              || { echo "FAIL: bundle check (gems not fully placed)"; exit 1; }
echo "[.bake/verify] OK: $(ruby -v); gems satisfied; bin/scan present"
