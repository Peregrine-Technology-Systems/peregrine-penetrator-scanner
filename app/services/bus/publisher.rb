# frozen_string_literal: true

module Bus
  # Scanner-side wrapper over the bus-identity adapter (peregrine_bus, scanner#1106).
  # The scanner emits scan.completed/failed + heartbeats through this, never raw
  # Pub/Sub or NATS — it does not consume from the bus (per the cross-TP landing-zone
  # decision: the launcher
  # consumes scan.requested and hands the job to the VM via instance metadata; the
  # VM never subscribes to anything). The adapter owns subjects, envelope, crypto,
  # and the substrate/transport mapping; this wrapper adds the three scanner-side
  # concerns:
  #
  #   1. Disabled mode — until infra injects BUS_BUCKET/BUS_KEYSET_PATH at the
  #      `.stage` soak (#1106), `build` returns a publisher with no adapter that
  #      no-ops. The durable GCS control/ writes remain the signal until then.
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

    # Construct a publisher over a concrete substrate + transport + key provider —
    # the seam the tests (MemorySubstrate + MemoryTransport + StaticKeyProvider) and
    # the future deploy wiring use. `transport` defaults to a MemoryTransport so
    # existing single-arg call sites (substrate + key_provider only) keep working.
    def self.for(substrate:, key_provider:, transport: Peregrine::Bus::MemoryTransport.new, t_mode: false)
      new(Peregrine::Bus::Adapter.new(substrate:, transport:, key_provider:, t_mode:))
    end

    def initialize(adapter)
      @adapter = adapter
    end

    def enabled?
      !@adapter.nil?
    end

    # Seal + write `payload` (a Hash) to a canonical subject. Returns the sealed
    # blob's object id (the claim-check `blob_uri`), or nil when disabled / on a
    # publish error (the GCS control/ write is the durable fallback in both cases).
    # `job_id`/`status` ride the clear claim-check pointer so a fan-out observer
    # can project lifecycle without opening the blob (ADR 0006).
    def publish(subject, payload, job_id: nil, status: nil)
      unless @adapter
        Penetrator.logger.debug("[Bus] disabled — drop subject=#{subject}")
        return nil
      end

      @adapter.publish(subject, JSON.generate(payload), job_id: job_id, status: status).blob_uri
    rescue StandardError => e
      Penetrator.logger.warn("[Bus] publish failed (#{subject}): #{e.message}")
      nil
    end
  end
end
