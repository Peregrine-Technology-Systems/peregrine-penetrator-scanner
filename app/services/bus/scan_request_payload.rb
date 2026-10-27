# frozen_string_literal: true

require 'uri'

module Bus
  # Normalizes the orchestrator's scan.requested payload shape (confirmed
  # 2026-07-20 against peregrine-penetrator-orchestrator's LifecycleEmitter,
  # scanner#1164): { job_id, status, transaction_id, environment, smoke,
  # target_url, profile }. Earlier scanner-side code (bin/scan pre-#1164)
  # guessed at target_name/urls (plural) — neither exists in the real
  # contract: there is no target_name field (client_id is deliberately not
  # leaked onto the scan payload), and it's target_url (singular), not urls.
  class ScanRequestPayload
    def initialize(raw)
      @raw = raw || {}
    end

    def job_id
      @raw['job_id']
    end

    def transaction_id
      @raw['transaction_id']
    end

    def environment
      @raw['environment']
    end

    def profile
      @raw['profile']
    end

    # No target_name field exists in the real contract — derive a best-effort
    # name from the URL host rather than defaulting every bus-triggered scan
    # to the literal "Default Target".
    def target_name
      return nil unless url

      URI.parse(url).host
    rescue URI::InvalidURIError
      nil
    end

    def target_urls
      url && [url]
    end

    private

    # The trimmed target_url, or nil when it is absent, empty or only whitespace
    # (#1241) — all of which mean "no target", never a URL to scan.
    def url
      value = @raw['target_url'].to_s.strip
      value.empty? ? nil : value
    end
  end
end
