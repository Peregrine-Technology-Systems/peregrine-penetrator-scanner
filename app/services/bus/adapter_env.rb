# frozen_string_literal: true

module Bus
  # Resolves the runtime bus adapter from the environment (scanner#1106).
  #
  # Disabled (nil) unless the substrate + keyset env vars are present — so every
  # existing deploy that doesn't set them keeps running fully off-bus (the GCS
  # control/ writes stay the durable signal). Real wiring activates only once
  # infra injects BUS_BUCKET + BUS_KEYSET_PATH at the `.stage` soak per #1106 —
  # this repo does not flip transports or environments on its own.
  #
  # Transport is chosen by BUS_TRANSPORT (default "pubsub"):
  #   pubsub -> Peregrine::Bus::Gcp::PubSubTransport   (production concrete)
  #   nats   -> Peregrine::Bus::Nats::NatsTransport    (`.stage` soak only — no
  #             live Synadia creds are provisioned yet, peregrine-bus#22)
  #
  # The Substrate (Plane 1, sealed blobs) is always GCS regardless of transport —
  # only the clear claim-check pointer's carrier (Plane 2) changes.
  module AdapterEnv
    module_function

    def adapter
      return nil unless enabled?

      transport = build_transport
      return nil unless transport

      require 'peregrine/bus/gcp'
      require 'google/cloud/storage'
      Peregrine::Bus::Adapter.new(
        substrate: Peregrine::Bus::Gcp::GcsSubstrate.new(client: Google::Cloud::Storage.new, bucket: ENV.fetch('BUS_BUCKET')),
        transport: transport,
        key_provider: Peregrine::Bus::StaticKeyProvider.from_file(ENV.fetch('BUS_KEYSET_PATH')),
        t_mode: ENV['BUS_T_MODE'] == 'true'
      )
    rescue StandardError => e
      Penetrator.logger.warn("[Bus] adapter construction failed: #{e.message}")
      nil
    end

    def enabled?
      ENV['BUS_BUCKET'].to_s.present? && ENV['BUS_KEYSET_PATH'].to_s.present?
    end

    def build_transport
      case ENV.fetch('BUS_TRANSPORT', 'pubsub')
      when 'pubsub'
        require 'peregrine/bus/gcp'
        require 'google/cloud/pubsub'
        Peregrine::Bus::Gcp::PubSubTransport.new(client: Google::Cloud::PubSub.new)
      when 'nats'
        require 'peregrine/bus/nats'
        require 'nats/client'
        js = NATS.connect(ENV.fetch('NATS_URL')).jetstream
        Peregrine::Bus::Nats::NatsTransport.new(client: js)
      end
    end
  end
end
