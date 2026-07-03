#!/usr/bin/env bash
# Post-scrub sanity for txn-scanner-app. Runs AFTER the baker strips build tools.
# Asserts the runtime is intact and gems are placed — NEVER installs.
set -euo pipefail
command -v ruby   >/dev/null || { echo "FAIL: ruby not on PATH"; exit 1; }
test -f bin/scan          || { echo "FAIL: bin/scan missing"; exit 1; }
bundle check              || { echo "FAIL: bundle check (gems not fully placed)"; exit 1; }

# Assert every probe binary survived the post-scrub image (scanner#1012). The list
# is derived from SCANNER_MAP (each scanner's EXECUTABLE — the same constant its
# command spawns), so this gate can't drift from what actually runs. A missing
# binary here means a base-install gap or a scrub over-reach; either fails the bake
# now instead of surfacing as a mid-scan "command not found" in production.
PROBE_TOOLS=$(bundle exec ruby -e '
  require "./app/services/scanner_base"
  Dir.glob("./app/services/scanners/*_scanner.rb").sort.each { |f| require f }
  require "./app/services/scan_orchestrator"
  require "./app/services/smoke_checker"
  puts SmokeChecker.new(nil).required_tools.join("\n")
') || { echo "FAIL: could not derive probe tool list"; exit 1; }

MISSING=""
for t in $PROBE_TOOLS; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -n "$MISSING" ] && { echo "FAIL: probe binaries missing from PATH:$MISSING"; exit 1; }

# Runtime dependencies the EXECUTABLE-derived list above can't capture — a probe's
# shim can be on PATH while its interpreter/runtime is absent, so the binary check
# passes but the probe dies at runtime (silent-OK). Assert them positively
# (scanner#1026): `retire` is a Node tool (needs `node`), `zap` execs a JVM (needs
# `java`), and `nmap` is the recon tool infra bakes for future recon use.
MISSING_DEPS=""
for d in node java nmap; do
  command -v "$d" >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $d"
done
[ -n "$MISSING_DEPS" ] && { echo "FAIL: probe runtime deps missing from PATH:$MISSING_DEPS"; exit 1; }

# Positively assert the baked sqlmap recognizes --report-json (scanner#822/#1069).
# The SqlmapParser reads sqlmap's --report-json output; the flag is absent below
# sqlmap 1.10.7. `command -v sqlmap` above only proves the binary exists — a base
# pinned to the old 1.8.9 would pass every check above and then silently emit zero
# SQLi findings in production (the flag would be an "unrecognized argument"). Grep
# the advanced help so a base regression fails the bake HERE, loudly, instead of as
# a silent-OK empty result in a real scan.
sqlmap -hh 2>&1 | grep -q -- '--report-json' \
  || { echo "FAIL: baked sqlmap does not support --report-json (base pin < 1.10.7); SqlmapParser would silently emit zero findings"; exit 1; }

echo "[.bake/verify] OK: $(ruby -v); gems satisfied; bin/scan present; all probe tools on PATH ($(echo "$PROBE_TOOLS" | tr '\n' ' ')); runtime deps present (node java nmap); sqlmap supports --report-json"
