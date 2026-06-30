#!/usr/bin/env bash
set -euo pipefail
# Runtime entrypoint for the baked txn-scanner-app — the scan-launcher baked-app
# path (#995). cwd is /opt/app; the launcher has already exported
# SCAN_PROFILE / TARGET_NAME / TARGET_URLS / SCAN_MODE / GCS_BUCKET from the request
# metadata (bin/scan also reads BOOT_IMAGE from the metadata server), and the
# launcher owns the VM lifecycle/self-delete — so unlike the old bootstrap.sh this
# does NOT self-delete. Symmetric to .bake/install.sh. Retires bootstrap_artifact.
exec bundle exec bin/scan
