# frozen_string_literal: true

require 'google/cloud/secret_manager'
require 'base64'

module Bus
  # Self-fetches the bus keyset from Secret Manager via the instance SA's ADC
  # (scanner#1182, arch#672 -- the self-fetching TP model replaces the
  # launcher-injected /dev/shm/keyset.json file, confirmed a dev-environment
  # artifact, not the production target).
  #
  # Naming + decode confirmed against infra directly (2026-07-20) and verified
  # against the authoritative reference
  # (peregrine-infrastructure/scripts/activation-check/
  # seal_and_publish_analysis_requested.py fn resolve_seal_key) rather than
  # taken on their word alone: project peregrine-production, two-step fetch
  # ("txn-monitor-cur--<sanitized subject>" -> current version, then
  # "txn-monitor-key--<sanitized subject>-<version>" -> key material). Key
  # material is RAW 32 bytes primarily; a base64 form is accepted ONLY if it
  # decodes to exactly 32 bytes (mirrors resolve_seal_key's own fallback) --
  # do not assume base64-always, that was this class's first-draft bug.
  #
  # NOTE (infra, 2026-07-20): a SHARED SM-backed KeyProvider is landing in the
  # peregrine_bus gem itself (peregrine-bus#70) so the penetrator trio doesn't
  # fork three copies of this exact fetch. This class is the interim/scanner
  # in-repo implementation -- swap to Peregrine::Bus::SmKeyProvider once #70
  # ships rather than maintaining this in parallel.
  #
  # Scoped to the DATA-plane subjects only (scan.requested/completed/failed) --
  # whether TELEMETRY-plane subjects (per-instance, tp_id embedded in the
  # subject string) use the same per-literal-subject keying, or need a
  # template/wildcard key lookup instead, is an open question flagged back to
  # infra rather than guessed here. Bus::Publisher#publish already fails soft
  # per-call, so a missing telemetry key degrades a heartbeat publish rather
  # than crashing the worker.
  class KeysetFetcher
    CURRENT_SECRET_TEMPLATE = 'txn-monitor-cur--%<subject>s'
    KEY_SECRET_TEMPLATE = 'txn-monitor-key--%<subject>s-%<version>s'
    RAW_KEY_BYTES = 32

    def initialize(project: ENV.fetch('BUS_KEYSET_PROJECT', 'peregrine-production'),
                   client: Google::Cloud::SecretManager.secret_manager_service)
      @project = project
      @client = client
    end

    # Builds a Peregrine::Bus::StaticKeyProvider holding the current key for
    # each of `subjects`. Fail-loud by design (scanner#1182): any missing
    # secret, denied grant, or wrong-length key raises -- a self-fetching TP
    # with a real bus subject to serve must never degrade to running silently
    # off-bus, nor seal/open with a corrupt key.
    def fetch(*subjects)
      current = {}
      keys = {}

      subjects.each do |subject|
        slug = subject.tr('.', '-')
        version = latest_secret_value(format(CURRENT_SECRET_TEMPLATE, subject: slug))
        current[subject] = version.to_i
        raw_key = latest_secret_value(format(KEY_SECRET_TEMPLATE, subject: slug, version:))
        # StaticKeyProvider.from_hash always base64-decodes "keys" values, so
        # re-encode the resolved 32 raw bytes to hand it what it expects.
        keys["#{subject}:#{version}"] = Base64.strict_encode64(resolve_key_bytes(raw_key, secret: subject))
      end

      Peregrine::Bus::StaticKeyProvider.from_hash('current' => current, 'keys' => keys)
    end

    private

    # Mirrors resolve_seal_key's exact fallback: accept raw 32 bytes, else a
    # base64 form that decodes to exactly 32 bytes, else fail loud -- never
    # silently accept a wrong-length key.
    def resolve_key_bytes(raw_key, secret:)
      return raw_key if raw_key.bytesize == RAW_KEY_BYTES

      decoded = begin
        Base64.strict_decode64(raw_key)
      rescue ArgumentError
        nil
      end
      return decoded if decoded&.bytesize == RAW_KEY_BYTES

      raise "seal key for #{secret.inspect} is #{raw_key.bytesize} bytes " \
            "(expected #{RAW_KEY_BYTES} raw or base64 thereof) -- refusing " \
            'to seal/open with a wrong-length key'
    end

    def latest_secret_value(secret_id)
      name = "projects/#{@project}/secrets/#{secret_id}/versions/latest"
      @client.access_secret_version(name:).payload.data
    end
  end
end
