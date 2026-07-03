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

# ── Probe tools (#1026): scanner-specific probe binaries not (yet) in the oven
# base catalog. apt/pip/npm are available in the app bake pre-scrub; the installed
# tools survive the scrub (only build-essential/gcc/make are purged). Eventual
# home: the declarative oven catalog once its apt/pip/npm admission plane exists
# (tracked in the infrastructure repo). Until then these are our app-layer deps,
# like our gems. ──
# Pinned probe-tool versions (#821) — deterministic, traceable scanner-base builds.
# apt/npm fail loudly (set -e) if a pin is unavailable; that IS the signal to bump
# deliberately rather than drift silently. Kept in lockstep with .bake/probe-versions.txt.
# (The base-image tools — ZAP, sqlmap, nuclei, ffuf, trufflehog, testssl, amass — are
# pinned in the infra oven catalog, not here; tracked in the infrastructure repo.)
NIKTO_VERSION="1:2.1.5-3.1"   # Ubuntu 24.04 (noble) multiverse
RETIRE_VERSION="5.4.3"        # npm
SCHEMATHESIS_VERSION="4.22.1" # pip (parser alignment, #1018/#1020)

sudo apt-get update -qq
sudo apt-get install -y -qq "nikto=${NIKTO_VERSION}" nmap python3-venv
# schemathesis in a dedicated venv (#1033), NOT a system pip install. Bare
# `pip install --break-system-packages` fought Debian-managed site-packages
# (typing_extensions had no RECORD → uninstall abort, #1033). A venv isolates
# schemathesis + all its deps from system Python entirely — no --break-system /
# --ignore-installed whack-a-mole — and matches the original intent (#1026). The
# entrypoint is symlinked onto PATH so `command -v schemathesis` (verify.sh)
# resolves. Pin 4.x → parser alignment (#1018/#1020).
sudo python3 -m venv /opt/schemathesis
sudo /opt/schemathesis/bin/pip install --quiet "schemathesis==${SCHEMATHESIS_VERSION}"
sudo ln -sf /opt/schemathesis/bin/schemathesis /usr/local/bin/schemathesis
# retire.js needs Node 20+ (ubuntu 24.04 apt nodejs is too old) → NodeSource 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
sudo apt-get install -y -qq nodejs
sudo npm install -g "retire@${RETIRE_VERSION}" >/dev/null
echo "[.bake/install] probe tools (pinned): nikto=$(nikto -Version 2>/dev/null | awk '/Nikto/{print $NF; exit}' || command -v nikto || echo MISSING) schemathesis=$(schemathesis --version 2>/dev/null || echo MISSING) retire=$(retire --version 2>/dev/null || echo MISSING) nmap=$(command -v nmap || echo MISSING)"
