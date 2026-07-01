# frozen_string_literal: true

module Bus
  # Resolves the runtime bus adapter from the environment (scanner#1009).
  #
  # Returns nil today — the production substrate package (`peregrine_bus_gcs`) is a
  # fast-follow and the Monitor-injected keyset (#4159) is not wired yet, so there
  # is nothing to bind to outside tests. `Bus::Publisher.build` therefore runs
  # disabled (no-op) in every real environment, and the durable GCS control/ writes
  # remain the completion + liveness signal until deploy injects both.
  #
  # When the GCS substrate ships, this becomes:
  #   Peregrine::Bus::Adapter.new(
  #     substrate:    PeregrineBusGcs::Substrate.new(bucket: ENV['BUS_BUCKET']),
  #     key_provider: Peregrine::Bus::StaticKeyProvider.from_file(ENV['BUS_KEYSET_PATH'])
  #   )
  # gated on both env vars being present — absent either, stay disabled.
  module AdapterEnv
    module_function

    def adapter
      nil
    end
  end
end
