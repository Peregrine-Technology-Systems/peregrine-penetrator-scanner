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

    # Test seam — clears the memoised value between examples.
    def reset!
      @boot_image = nil
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
