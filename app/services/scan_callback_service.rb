# frozen_string_literal: true

class ScanCallbackService
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  def initialize(scan, cost_logger, gcs_scan_results_path: nil)
    @scan = scan
    @cost_logger = cost_logger
    @gcs_scan_results_path = gcs_scan_results_path
  end

  def notify
    return false unless self.class.enabled?

    payload = build_payload

    if self.class.stub_mode?
      Penetrator.logger.info("[ScanCallbackService] STUB: #{payload.to_json}")
      return true
    end

    post_with_retries(payload)
  end

  def self.stub_mode?
    ENV.fetch('SCAN_PROFILE', '') == 'smoke-test'
  end

  def self.enabled?
    ENV['CALLBACK_URL'].present?
  end

  private

  def build_payload
    payload = {
      scan_uuid: ENV.fetch('SCAN_UUID', @scan.id),
      job_id: ENV.fetch('JOB_ID', nil),
      status: @scan.status,
      duration_seconds: @scan.duration&.to_i,
      summary: @scan.summary || {},
      gcs_scan_results_path: @gcs_scan_results_path,
      cost_data: @cost_logger.cost_data
    }
    payload.compact
  end

  def post_with_retries(payload)
    attempts = 0

    while attempts < MAX_RETRIES
      attempts += 1
      response = post_callback(payload)
      return true if response&.status&.between?(200, 299)

      Penetrator.logger.warn("[ScanCallbackService] Attempt #{attempts}/#{MAX_RETRIES} " \
                             "failed (status: #{response&.status})")
      sleep(RETRY_BASE_DELAY * attempts) if attempts < MAX_RETRIES
    end

    Penetrator.logger.error("[ScanCallbackService] Exhausted #{MAX_RETRIES} retries for #{callback_url}")
    write_dead_letter(payload)
    false
  rescue StandardError => e
    Penetrator.logger.error("[ScanCallbackService] Failed: #{e.message}")
    false
  end

  def write_dead_letter(payload)
    scan_uuid = payload[:scan_uuid] || @scan.id
    dead_letter = payload.merge(failed_at: Time.current.iso8601)
    path = "control/#{scan_uuid}/callback_pending.json"

    StorageService.new.upload_json(path, dead_letter)
    Penetrator.logger.warn("[ScanCallbackService] Dead letter written to GCS: #{path}")
  rescue StandardError => e
    Penetrator.logger.error("[ScanCallbackService] Dead letter write failed: #{e.message}")
  end

  def post_callback(payload)
    connection.post(callback_url) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{callback_secret}"
      req.body = payload.to_json
    end
  end

  def connection
    @connection ||= Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 10
      f.options.open_timeout = 5
    end
  end

  def callback_url
    ENV.fetch('CALLBACK_URL')
  end

  def callback_secret
    ENV.fetch('SCAN_CALLBACK_SECRET', '')
  end
end
