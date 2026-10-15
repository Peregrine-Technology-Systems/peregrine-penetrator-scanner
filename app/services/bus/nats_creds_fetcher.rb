# frozen_string_literal: true

require 'google/cloud/secret_manager'
require 'fileutils'

module Bus
  # Self-fetches the Synadia NATS .creds file from Secret Manager via the
  # instance SA's ADC (scanner#1182) and writes it to the same tmpfs path +
  # mode-0600 discipline the launcher used to inject it at -- only the SOURCE
  # changes (Secret Manager instead of boot metadata), not the security
  # posture: never touches persistent disk, cleared with the rest of
  # /dev/shm/peregrine on VM teardown.
  #
  # Confirmed against infra directly (2026-07-20): one shared secret,
  # peregrine-production--synadia-creds, project peregrine-production. Payload
  # IS the raw .creds content (JWT+nkey) -- used directly, no JSON wrap.
  class NatsCredsFetcher
    SECRET_ID = 'peregrine-production--synadia-creds'
    DEFAULT_PATH = '/dev/shm/peregrine/synadia.creds'

    def initialize(project: ENV.fetch('BUS_KEYSET_PROJECT', 'peregrine-production'),
                   client: Google::Cloud::SecretManager.secret_manager_service,
                   path: DEFAULT_PATH)
      @project = project
      @client = client
      @path = path
    end

    # Fetches the creds content and writes it to `path`. Returns the path --
    # the shape NATS.connect(user_credentials:) expects. Fail-loud: any
    # Secret Manager error (missing secret, denied grant) raises rather than
    # degrading to a nil/unauthenticated connect.
    def fetch
      name = "projects/#{@project}/secrets/#{SECRET_ID}/versions/latest"
      content = @client.access_secret_version(name:).payload.data

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, content)
      File.chmod(0o600, @path)
      @path
    end
  end
end
