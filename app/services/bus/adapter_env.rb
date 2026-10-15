# frozen_string_literal: true

module Bus
  # Resolves the runtime bus adapter from the environment (scanner#1106,
  # self-fetch model scanner#1182 / arch#672).
  #
  # Two distinct postures, discriminated by InstanceMetadata.on_gce?:
  #
  # - ON GCE (a real deployed TP instance): the bus is MANDATORY, never
  #   optional, and construction is FAIL-LOUD (scanner#1182 — the
  #   self-fetching TP model explicitly rules out silent-idle: an
  #   unprovisioned/mis-granted TP must crash at boot, diagnosable, not run
  #   quietly off-bus). Keyset is self-fetched via peregrine-bus#70's shared
  #   `Peregrine::Bus::Gcp::SmKeyProvider` (fanned across our 3 data-plane
  #   subjects by CompositeKeyProvider — SmKeyProvider is scoped to exactly
  #   one subject per instance, verified against its shipped source); Synadia
  #   creds are self-fetched via our own NatsCredsFetcher (a separate concern,
  #   not covered by #70). The launcher-injected /dev/shm/keyset.json +
  #   NATS_CREDS file model is a confirmed dev-environment artifact, not the
  #   production target.
  # - OFF GCE (local dev, CI, tests): unchanged from #1106 — disabled (nil)
  #   unless BUS_BUCKET + BUS_KEYSET_PATH are explicitly set, fail-soft on any
  #   construction error. Every existing dev/CI workflow is untouched.
  #
  # Transport is chosen by BUS_TRANSPORT (default "pubsub" off-GCE, "nats" on
  # GCE — the interim corporate-bus flip, scanner#1135, is the production
  # transport now). On GCE, NATS connects DIRECTLY to connect.ngs.global (no
  # local nats-leaf — also a dev-environment artifact per arch#672).
  module AdapterEnv
    module_function

    # The data-plane subjects this TP needs key material for for
    # self-fetch (scanner#1182). Telemetry-plane subjects (start/heartbeat/
    # exiting) are per-instance — whether they key the same way is an open
    # question flagged back to infra, not guessed here; Bus::Publisher#publish
    # already fails soft per-call, so a missing telemetry key degrades a
    # heartbeat publish rather than crashing the worker.
    DATA_PLANE_SUBJECTS = [
      Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'requested'),
      Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'completed'),
      Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed')
    ].freeze

    def adapter
      return nil unless enabled?

      transport = build_transport
      return nil unless transport

      Peregrine::Bus::Adapter.new(
        substrate: substrate,
        transport: transport,
        key_provider: key_provider,
        t_mode: ENV['BUS_T_MODE'] == 'true'
      )
    rescue StandardError => e
      raise if InstanceMetadata.on_gce?

      Penetrator.logger.warn("[Bus] adapter construction failed: #{e.message}")
      nil
    end

    def enabled?
      return true if InstanceMetadata.on_gce?

      ENV['BUS_BUCKET'].to_s.present? && ENV['BUS_KEYSET_PATH'].to_s.present?
    end

    # The GCS substrate (Plane 1, sealed blobs) — shared by #adapter and by
    # Bus::JobPointerResolver (scanner#1124), which only needs substrate +
    # key_provider (no transport) to open an already-known claim-check pointer.
    # Instance-SA ADC already works correctly here (infra confirmed on
    # scanner#1182) — no self-fetch change needed, ENV.fetch's raise-on-missing
    # already satisfies fail-loud on GCE.
    def substrate
      require 'peregrine/bus/gcp'
      require 'google/cloud/storage'
      Peregrine::Bus::Gcp::GcsSubstrate.new(client: Google::Cloud::Storage.new, bucket: ENV.fetch('BUS_BUCKET'))
    end

    def key_provider
      return self_fetch_key_provider if InstanceMetadata.on_gce?

      Peregrine::Bus::StaticKeyProvider.from_file(ENV.fetch('BUS_KEYSET_PATH'))
    end

    def self_fetch_key_provider
      require 'peregrine/bus/gcp'
      CompositeKeyProvider.for_subjects(
        *DATA_PLANE_SUBJECTS,
        provider_class: Peregrine::Bus::Gcp::SmKeyProvider,
        project: ENV.fetch('BUS_KEYSET_PROJECT', Peregrine::Bus::Gcp::SmKeyProvider::DEFAULT_PROJECT)
      )
    end

    def build_transport
      case ENV.fetch('BUS_TRANSPORT', InstanceMetadata.on_gce? ? 'nats' : 'pubsub')
      when 'pubsub'
        require 'peregrine/bus/gcp'
        require 'google/cloud/pubsub'
        Peregrine::Bus::Gcp::PubSubTransport.new(client: Google::Cloud::PubSub.new)
      when 'nats'
        build_nats_transport
      end
    end

    def build_nats_transport
      require 'peregrine/bus/nats'
      require 'nats/client'

      creds = InstanceMetadata.on_gce? ? NatsCredsFetcher.new.fetch : ENV.fetch('NATS_CREDS', nil)
      return nil if creds.to_s.empty?

      # No local nats-leaf — connect directly to Synadia (arch#672). Off-GCE
      # NATS_URL stays explicit (dev/CI point at a local leaf or test server).
      url = ENV.fetch('NATS_URL', InstanceMetadata.on_gce? ? 'connect.ngs.global' : nil)
      js = NATS.connect(url, user_credentials: creds).jetstream
      Peregrine::Bus::Nats::NatsTransport.new(client: js)
    end
  end
end
