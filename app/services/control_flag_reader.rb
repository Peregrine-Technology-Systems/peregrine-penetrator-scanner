class ControlFlagReader
  def initialize(gcs_bucket:, scan_uuid:)
    @gcs_bucket = gcs_bucket
    @scan_uuid = scan_uuid
  end

  def cancelled?
    # Stub — full implementation in #378
    false
  end

  def self.enabled?
    ENV['GCS_BUCKET'].present? && ENV['GOOGLE_CLOUD_PROJECT'].present?
  end
end
