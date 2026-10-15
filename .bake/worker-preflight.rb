#!/usr/bin/env ruby
# frozen_string_literal: true

# ExecStartPre for scanner-worker.service (#1209): refuse to start with an incomplete
# environment, naming every missing variable at once. A MIG worker with no bus must
# fail visibly, never idle green. Plain ruby (no gems): runs before bundler loads.
REQUIRED = %w[NATS_URL BUS_BUCKET BUS_KEYSET_PROJECT GOOGLE_CLOUD_PROJECT].freeze

missing = REQUIRED.select { |name| ENV.fetch(name, '').strip.empty? }
exit 0 if missing.empty?

warn "scanner-worker preflight FAILED: missing or blank in /etc/peregrine/scanner.env: #{missing.join(', ')}"
exit 1
