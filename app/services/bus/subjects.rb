# frozen_string_literal: true

module Bus
  # Canonical penetrator subject grammar, ratified on the four-plane bus scheme.
  # The scanner is **publish-side only** (scanner#1005): it emits scan-stage task
  # state on the *data* plane and instance liveness on the *telemetry* plane. It
  # never hand-names a Pub/Sub topic.
  #
  # These constants are a local, test-asserted encoding of the ratified grammar —
  # a placeholder for infra's forthcoming Subjects module in the bus-identity
  # adapter. When the adapter lands, subject construction + validation move there
  # and these are asserted against it before any call-site is wired. Until then they
  # let the seam and its payload-shape guard bind to the right names.
  module Subjects
    # data plane — scan-stage task lifecycle of the single `penetrator` task class
    SCAN_COMPLETED = 'data.task.penetrator.scan.completed'
    SCAN_FAILED    = 'data.task.penetrator.scan.failed'

    # telemetry plane — instance liveness root (see Subjects.scan_heartbeat)
    HEARTBEAT_PREFIX = 'telemetry.tp.scanner.heartbeat'

    module_function

    # Map a terminal scanner state to its data-plane completion subject.
    # success/completed -> .completed; failed/upload_failed -> .failed.
    def scan_terminal(state)
      case state.to_s
      when 'completed', 'success' then SCAN_COMPLETED
      when 'failed', 'upload_failed' then SCAN_FAILED
      else raise ArgumentError, "unknown scan terminal state: #{state.inspect}"
      end
    end

    # Liveness is keyed by **tp-id alone** (the ratified four-plane bus scheme): one row per scanner
    # instance, overwritten per beat. The in-flight transaction_id(s) ride in the
    # heartbeat *value*, never the key — keying by (tp-id, scan_uuid) would strand
    # stale rows on completed scans and trip false re-injection.
    def scan_heartbeat(tp_id)
      raise ArgumentError, 'tp_id required for heartbeat subject' if tp_id.to_s.empty?

      "#{HEARTBEAT_PREFIX}.#{tp_id}"
    end
  end
end
