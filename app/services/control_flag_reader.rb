class ControlFlagReader
  def initialize(gcs_bucket:, scan_uuid:)
    @gcs_bucket = gcs_bucket
    @scan_uuid = scan_uuid
  end

  def cancelled?
    control_path = "control/#{@scan_uuid}/control.json"
    file = bucket.file(control_path)
    return false unless file

    content = file.download
    data = JSON.parse(content.read)
    data['action'] == 'cancel'
  rescue StandardError => e
    Penetrator.logger.warn("[ControlFlagReader] Check failed: #{e.message}")
    false
  end

  def self.enabled?
    ENV['GCS_BUCKET'].present? && ENV['GOOGLE_CLOUD_PROJECT'].present?
  end

  private

  def bucket
    require 'google/cloud/storage'
    storage = Google::Cloud::Storage.new
    storage.bucket(@gcs_bucket)
  end
end
