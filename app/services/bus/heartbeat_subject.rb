# frozen_string_literal: true

module Bus
  # The subject the scanner publishes its liveness telemetry on, one place for
  # ControlPlaneLoop (running beats) and WorkerLoop (exiting).
  #
  # This is the per-instance `telemetry.tp.scanner.heartbeat.<tp-id>` shape the
  # scanner has always published (the same generic builder `publish_bus_start`
  # uses). peregrine_bus 0.8.0's `Penetrator.scanner_heartbeat` now returns a
  # different, tp-id-free subject (`telemetry.penetrator.scan.heartbeat`), so
  # the gem helper can no longer be called with a tp-id. Moving the scanner onto
  # the gem's subject is a wire-contract change for tp-monitor's consumer, so it
  # is left to that decision (#1231) instead of riding in with the gem bump.
  module HeartbeatSubject
    module_function

    def for(tp_id)
      Peregrine::Bus::Subjects.telemetry('tp', 'scanner', 'heartbeat', tp_id)
    end
  end
end
