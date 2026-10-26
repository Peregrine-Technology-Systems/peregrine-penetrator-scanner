#!/usr/bin/env ruby
# frozen_string_literal: true

# ExecStartPre for scanner-worker.service (#1209): refuse to start with an incomplete
# environment, naming every missing variable at once. A MIG worker with no bus must
# fail visibly, never idle green. Plain ruby (no gems): runs before bundler loads.
# GCS_BUCKET is required because StorageService silently falls back to LOCAL DISK when it
# is unset (#942): a worker would scan, report completed, and lose every result when the
# ephemeral VM exits.
# APP_ENV is required because it selects the bus grammar token (#1243): the scanner never
# reads RACK_ENV, and the default ("development") would put a production worker on the dev
# subject, where it would idle green and never see work.
# ORGANIZATION_ID is the publisher organization for envelope v2 (#1229): without it every
# scan.completed / scan.failed publish is refused, so a worker would finish scans and report nothing.
REQUIRED = %w[NATS_URL BUS_BUCKET BUS_KEYSET_PROJECT GOOGLE_CLOUD_PROJECT GCS_BUCKET APP_ENV ORGANIZATION_ID].freeze

missing = REQUIRED.select { |name| ENV.fetch(name, '').strip.empty? }
exit 0 if missing.empty?

warn "scanner-worker preflight FAILED: missing or blank in /etc/peregrine/scanner.env: #{missing.join(', ')}"
exit 1
