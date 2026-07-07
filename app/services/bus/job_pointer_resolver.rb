# frozen_string_literal: true

module Bus
  # Resolves job identity from the launcher's BUS_JOB_POINTER claim-check
  # (scanner#1124): the launcher-consumes landing zone hands the VM a clear
  # ClaimCheck pointer via
  # instance metadata -> tmpfs (`/dev/shm/peregrine/bus-job-pointer.json`,
  # byte-for-byte the same discipline as the KEYSET injection) — never the
  # decrypted payload. The VM opens it itself with its own keyset.
  #
  # Fail-soft when the pointer file is absent — today's only live path, since
  # no bus-triggered launch exists yet. Fail LOUD (raise) when the file is
  # present but the blob can't be opened: a bus-triggered launch with an
  # unopenable pointer has no other source of truth and must not silently
  # proceed against ENV/CLI defaults (silent-OK discipline).
  class JobPointerResolver
    DEFAULT_PATH = '/dev/shm/peregrine/bus-job-pointer.json'

    def initialize(path: ENV.fetch('BUS_JOB_POINTER_PATH', DEFAULT_PATH), substrate: nil, key_provider: nil)
      @path = path
      @substrate = substrate
      @key_provider = key_provider
    end

    # The decoded job-detail Hash — whatever Orchestrator::LifecycleEmitter
    # actually publishes for the job (job_id/status/transaction_id/environment
    # as of scanner#1124; see that issue for the target/profile data gap) — or
    # nil if there is no bus job pointer to resolve.
    def resolve
      return nil unless File.exist?(@path)

      pointer = Peregrine::Bus::ClaimCheck.parse(File.read(@path))
      sealed = substrate.get(pointer.blob_uri)
      plaintext = Peregrine::Bus::Envelope.parse(sealed).open(key_provider: key_provider, expected_subject: pointer.subject)
      JSON.parse(plaintext)
    end

    private

    def substrate
      @substrate ||= AdapterEnv.substrate
    end

    def key_provider
      @key_provider ||= AdapterEnv.key_provider
    end
  end
end
