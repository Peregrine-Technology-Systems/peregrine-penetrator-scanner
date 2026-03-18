class StorageService
  def initialize
    @bucket_name = ENV.fetch('GCS_BUCKET', 'pentest-reports')
  end

  def upload(local_path, remote_path, content_type: 'application/octet-stream')
    if gcs_configured?
      upload_to_gcs(local_path, remote_path, content_type)
    else
      upload_local(local_path, remote_path)
    end
  end

  def signed_url(remote_path, expires_in: 7.days)
    if gcs_configured?
      gcs_signed_url(remote_path, expires_in)
    else
      "file://#{local_storage_path(remote_path)}"
    end
  end

  private

  def gcs_configured?
    ENV['GOOGLE_CLOUD_PROJECT'].present? && ENV['GCS_BUCKET'].present?
  end

  def upload_to_gcs(local_path, remote_path, content_type)
    require 'google/cloud/storage'
    storage = Google::Cloud::Storage.new
    bucket = storage.bucket(@bucket_name)
    file = bucket.create_file(local_path, remote_path, content_type:)
    Rails.logger.info("[StorageService] Uploaded to GCS: #{remote_path}")
    { path: remote_path, url: file.public_url }
  end

  def upload_local(local_path, remote_path)
    dest = local_storage_path(remote_path)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(local_path, dest)
    Rails.logger.info("[StorageService] Stored locally: #{dest}")
    { path: remote_path, url: "file://#{dest}" }
  end

  def gcs_signed_url(remote_path, expires_in)
    require 'google/cloud/storage'
    storage = Google::Cloud::Storage.new
    bucket = storage.bucket(@bucket_name)
    file = bucket.file(remote_path)
    file.signed_url(expires: expires_in.to_i, method: 'GET')
  end

  def local_storage_path(remote_path)
    Rails.root.join('storage', 'reports', remote_path).to_s
  end
end
