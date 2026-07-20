# frozen_string_literal: true

require 'net/http'

# Reads the running VM's identity from the GCE metadata server.
#
# Fail-safe by design: off-GCE (local dev, CI, tests where the metadata server
# is unreachable or blocked), every reader returns a sentinel instead of raising
# — a scan must never fail because instance metadata is unavailable (#951).
#
# Used for version traceability: the scan stamps its actual boot image into
# status.json and audit events, so a result is tied to the exact image that
# produced it without an org-side image lookup (which is DRS-walled).
class InstanceMetadata
  METADATA_BASE = 'http://metadata.google.internal/computeMetadata/v1/instance'
  UNKNOWN = 'unknown'

  class << self
    # Short name of the image the VM booted from
    # (e.g. "txn-scanner-app-20260628-v1-0-1"). Memoised — the image is constant
    # for the life of the process. Returns UNKNOWN off-GCE.
    def boot_image
      return @boot_image if defined?(@boot_image) && !@boot_image.nil?

      raw = fetch('image')
      @boot_image = raw.nil? || raw.empty? ? UNKNOWN : raw.split('/').last
    end

    # This scanner instance's bus identity (the `tp-id`, scanner#1005). Liveness
    # heartbeats are keyed by tp-id alone (per the ratified bus scheme), so it must
    # be stable for the life of the process and unique per instance. Uses the GCE
    # instance name;
    # fail-safe to $HOSTNAME, then UNKNOWN, off-GCE. Memoised.
    def tp_id
      return @tp_id if defined?(@tp_id) && !@tp_id.nil?

      raw = fetch('name')
      @tp_id = if raw.nil? || raw.empty?
                 ENV.fetch('HOSTNAME', nil).then { |h| h.to_s.empty? ? UNKNOWN : h }
               else
                 raw
               end
    end

    # True when the metadata server actually answers — the discriminator
    # between a real deployed TP instance and local dev/CI/tests (scanner#1182:
    # the self-fetching TP model is mandatory-and-fail-loud on GCE, optional
    # and fail-soft everywhere else). Memoised.
    def on_gce?
      return @on_gce if defined?(@on_gce) && !@on_gce.nil?

      @on_gce = !fetch('id').nil?
    end

    # Test seam — clears the memoised values between examples.
    def reset!
      @boot_image = nil
      @tp_id = nil
      @on_gce = nil
    end

    private

    def fetch(path)
      uri = URI("#{METADATA_BASE}/#{path}")
      req = Net::HTTP::Get.new(uri)
      req['Metadata-Flavor'] = 'Google'
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(req)
      end
      res.is_a?(Net::HTTPSuccess) ? res.body.strip : nil
    rescue StandardError
      nil
    end
  end
end
