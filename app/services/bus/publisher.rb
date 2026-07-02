# frozen_string_literal: true

module Bus
  # Scanner-side wrapper over the bus-identity adapter (peregrine_bus, scanner#1009).
  # The scanner is publish-side only: it emits scan.completed + heartbeats through
  # this, never raw Pub/Sub. The adapter owns subjects, envelope, crypto, and the
  # substrate mapping; this wrapper adds the three scanner-side concerns:
  #
  #   1. Disabled mode — the production substrate (peregrine_bus_gcs) and the
  #      Monitor-injected keyset land at deploy and are not present yet, so `build`
  #      returns a publisher with no adapter that no-ops. The durable GCS control/
  #      writes remain the signal until the substrate + keys are injected.
  #   2. Serialization — payload hashes are JSON-encoded to the bytes the adapter
  #      seals (the adapter takes opaque plaintext).
  #   3. Fail-soft — a bus publish must never fail a scan; on error we log and fall
  #      back to the durable GCS control/ write.
  class Publisher
    # Env-driven default. Disabled (no adapter) until a substrate + keyset are
    # wired at deploy. Tests and the deploy path use `.for` to inject a real adapter.
    def self.build
      new(AdapterEnv.adapter)
    end

    # Construct a publisher over a concrete substrate + key provider — the seam the
    # tests (MemorySubstrate + StaticKeyProvider) and the future deploy wiring use.
    def self.for(substrate:, key_provider:, t_mode: false)
      new(Peregrine::Bus::Adapter.new(substrate:, key_provider:, t_mode:))
    end

    def initialize(adapter)
      @adapter = adapter
    end

    def enabled?
      !@adapter.nil?
    end

    # Seal + write `payload` (a Hash) to a canonical subject. Returns the object id,
    # or nil when disabled / on a publish error (the GCS control/ write is the
    # durable fallback in both cases).
    def publish(subject, payload)
      unless @adapter
        Penetrator.logger.debug("[Bus] disabled — drop subject=#{subject}")
        return nil
      end

      @adapter.publish(subject, JSON.generate(payload))
    rescue StandardError => e
      Penetrator.logger.warn("[Bus] publish failed (#{subject}): #{e.message}")
      nil
    end
  end
end
