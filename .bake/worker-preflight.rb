#!/usr/bin/env ruby
# frozen_string_literal: true

# ExecStartPre for scanner-worker.service (#1209): refuse to start with an incomplete
# environment, naming every missing variable at once. A MIG worker with no bus must
# fail visibly, never idle green. Plain ruby (no gems): runs before bundler loads.
# GCS_BUCKET is required because StorageService silently falls back to LOCAL DISK when it
# is unset (#942): a worker would scan, report completed, and lose every result when the
# ephemeral VM exits.
REQUIRED = %w[NATS_URL BUS_BUCKET BUS_KEYSET_PROJECT GOOGLE_CLOUD_PROJECT GCS_BUCKET].freeze

missing = REQUIRED.select { |name| ENV.fetch(name, '').strip.empty? }
exit 0 if missing.empty?

warn "scanner-worker preflight FAILED: missing or blank in /etc/peregrine/scanner.env: #{missing.join(', ')}"
exit 1
