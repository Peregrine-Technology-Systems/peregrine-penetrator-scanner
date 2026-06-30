# frozen_string_literal: true

module Bus
  # Transport seam for bus publishes (scanner#1005). The scanner is publish-side
  # only, so this is the single point the publish substrate is bound. Call-sites
  # depend only on this interface, so the real bus-identity adapter (per-message
  # rotating key + AEAD + subject-as-AAD) drops in behind `build` without touching
  # ScanOrchestrator / ControlPlaneLoop / bin/scan.
  #
  # NOT YET WIRED: this seam ships ahead of the adapter and ahead of infra's
  # pre-wiring review of the concrete Subjects. `build` returns a NullPublisher, so
  # constructing a publisher is inert; the durable GCS control/ writes remain the
  # real signal until the adapter is wired and reviewed.
  class Publisher
    # @return [Publisher] the active publisher — NullPublisher until the adapter
    #   ships and is wired here (the one line that changes at cutover).
    def self.build
      NullPublisher.new
    end

    # @param subject [String] a canonical Bus::Subjects subject
    # @param payload [Hash] claim-check pointer + identity (never raw bytes)
    # @param key [String, nil] partition/liveness key (tp-id for heartbeats)
    def publish(subject:, payload:, key: nil)
      raise NotImplementedError, "#{self.class}#publish"
    end
  end
end
