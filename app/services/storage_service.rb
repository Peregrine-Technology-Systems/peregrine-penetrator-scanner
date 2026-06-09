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

  def upload_json(remote_path, data)
    tmpfile = Tempfile.new(['json', '.json'])
    tmpfile.write(data.to_json)
    tmpfile.close
    upload(tmpfile.path, remote_path, content_type: 'application/json')
  ensure
    tmpfile&.unlink
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
    file = gcs_bucket.create_file(local_path, remote_path, content_type:)
    Penetrator.logger.info("[StorageService] Uploaded to GCS: #{remote_path}")
    { path: remote_path, url: file.public_url }
  rescue StandardError => e
    # No silent local fallback when GCS is configured. A production scan VM's
    # whole purpose is to export to GCS; a local fallback writes to a container
    # path that is lost on --rm exit, while the scan still reports "completed" —
    # a silent-OK that hid lost results for months (#784). Fail loudly instead.
    raise "[StorageService] GCS upload to '#{@bucket_name}/#{remote_path}' failed: #{e.class}: #{e.message}"
  end

  def upload_local(local_path, remote_path)
    dest = local_storage_path(remote_path)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(local_path, dest)
    Penetrator.logger.info("[StorageService] Stored locally: #{dest}")
    { path: remote_path, url: "file://#{dest}" }
  end

  def gcs_signed_url(remote_path, expires_in)
    gcs_bucket.file(remote_path).signed_url(expires: expires_in.to_i, method: 'GET')
  end

  def gcs_bucket
    require 'google/cloud/storage'
    @gcs_client ||= Google::Cloud::Storage.new
    # skip_lookup: writing/reading objects needs storage.objects.*, NOT
    # storage.buckets.get — don't gate uploads on a bucket-metadata read, and
    # never return nil (which the old code turned into a silent local fallback).
    @gcs_client.bucket(@bucket_name, skip_lookup: true)
  end

  def local_storage_path(remote_path)
    Penetrator.root.join('storage', 'reports', remote_path).to_s
  end
end
