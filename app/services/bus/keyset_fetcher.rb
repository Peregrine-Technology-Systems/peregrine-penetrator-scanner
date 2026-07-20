# frozen_string_literal: true

require 'google/cloud/secret_manager'

module Bus
  # Self-fetches the bus keyset from Secret Manager via the instance SA's ADC
  # (scanner#1182, arch#672 — the self-fetching TP model replaces the
  # launcher-injected /dev/shm/keyset.json file, confirmed a dev-environment
  # artifact, not the production target).
  #
  # PLACEHOLDER naming pattern, pending infra confirmation (the SA grants are
  # landing in parallel on infra's side): for each subject, reads the current-version
  # pointer from "txn-monitor-cur--<subject-with-dashes>" and the key material
  # from "txn-monitor-key--<subject-with-dashes>-<version>", per infra's own
  # description on scanner#1182. Adjust the two SECRET_TEMPLATE constants once
  # confirmed — everything else here is stable regardless of the exact naming.
  #
  # Scoped to the DATA-plane subjects only (scan.requested/completed/failed) —
  # whether TELEMETRY-plane subjects (per-instance, tp_id embedded in the
  # subject string) use the same per-literal-subject keying, or need a
  # template/wildcard key lookup instead, is an open question flagged back to
  # infra rather than guessed here. Bus::Publisher#publish already fails soft
  # per-call, so a missing telemetry key degrades a heartbeat publish rather
  # than crashing the worker.
  class KeysetFetcher
    CURRENT_SECRET_TEMPLATE = 'txn-monitor-cur--%<subject>s'
    KEY_SECRET_TEMPLATE = 'txn-monitor-key--%<subject>s-%<version>s'

    def initialize(project: ENV.fetch('BUS_KEYSET_PROJECT', 'peregrine-pts-penetrator'),
                   client: Google::Cloud::SecretManager.secret_manager_service)
      @project = project
      @client = client
    end

    # Builds a Peregrine::Bus::StaticKeyProvider holding the current key for
    # each of `subjects`. Fail-loud by design (scanner#1182): any missing
    # secret or denied grant raises — a self-fetching TP with a real bus
    # subject to serve must never degrade to running silently off-bus.
    def fetch(*subjects)
      current = {}
      keys = {}

      subjects.each do |subject|
        slug = subject.tr('.', '-')
        version = latest_secret_value(format(CURRENT_SECRET_TEMPLATE, subject: slug))
        current[subject] = version.to_i
        keys["#{subject}:#{version}"] = latest_secret_value(format(KEY_SECRET_TEMPLATE, subject: slug, version:))
      end

      Peregrine::Bus::StaticKeyProvider.from_hash('current' => current, 'keys' => keys)
    end

    private

    def latest_secret_value(secret_id)
      name = "projects/#{@project}/secrets/#{secret_id}/versions/latest"
      @client.access_secret_version(name:).payload.data
    end
  end
end
