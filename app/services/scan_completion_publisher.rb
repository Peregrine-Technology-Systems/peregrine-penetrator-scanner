# frozen_string_literal: true

# Emits the bus `scan.completed` / `scan.failed` event for a finished scan
# (scanner#1009): a claim-check pointer to the exported report blob (bucket +
# object id + sha256), never the report bytes. The orchestrator consumes it as the
# fast completion signal.
#
# This mirrors — does not replace — the durable GCS `control/<scan_uuid>/status.json`
# write bin/scan still performs: the bus event is the fast path, the GCS status is
# the watchdog's fallback + crash-recovery source. Inert until the bus substrate is
# wired at deploy (Bus::Publisher.build is disabled meanwhile).
class ScanCompletionPublisher
  # Map the scan's terminal status onto the data-plane completion state (the bus
  # grammar only has completed/failed; cancelled is a failure to the saga).
  TERMINAL_STATE = { 'completed' => 'completed', 'failed' => 'failed', 'cancelled' => 'failed' }.freeze

  def initialize(scan, exporter:, identity:, publisher: Bus::Publisher.build)
    @scan = scan
    @exporter = exporter
    @identity = identity
    @publisher = publisher
  end

  def emit
    subject = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', state)
    @publisher.publish(subject, payload)
  end

  private

  def state
    TERMINAL_STATE.fetch(@scan.status, 'failed')
  end

  def payload
    @identity.to_h.merge(
      state: state,
      schema_version: ScanResultsExporter::SCHEMA_VERSION,
      scanner_result_uri: @exporter.claim_check,
      completed_at: Time.current.utc.iso8601
    )
  end
end
