# frozen_string_literal: true

module Bus
  # The scan-stage data-plane subjects, carrying the deploy environment's grammar
  # token (#1243). One place, so the consumer, the completion publisher, the
  # invalid-request reporter and the key-fetch list cannot disagree.
  # Computed on each call, never frozen into a constant at load time.
  module ScanSubjects
    module_function

    def requested
      stage_state('requested')
    end

    def terminal(state)
      stage_state(state)
    end

    # The subjects this worker needs key material for at self-fetch (scanner#1182).
    # Telemetry-plane subjects (start/heartbeat/exiting) are per-instance and not listed:
    # whether they key the same way is an open question flagged back to infra, and
    # Bus::Publisher#publish fails soft per call, so a missing telemetry key degrades a
    # heartbeat publish rather than crashing the worker.
    def data_plane
      %w[requested completed failed].map { |state| stage_state(state) }
    end

    def stage_state(state)
      Peregrine::Bus::Subjects::Penetrator.stage_state('scan', state, env: GrammarEnv.token)
    end
  end
end
