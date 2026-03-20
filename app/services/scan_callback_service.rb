# frozen_string_literal: true

class ScanCallbackService
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  def initialize(scan, cost_logger)
    @scan = scan
    @cost_logger = cost_logger
  end

  def notify
    return false unless self.class.enabled?

    payload = build_payload
    post_with_retries(payload)
  end

  def self.enabled?
    ENV['CALLBACK_URL'].present?
  end

  private

  def build_payload
    {
      scan_uuid: ENV.fetch('SCAN_UUID', @scan.id),
      status: @scan.status,
      duration_seconds: @scan.duration&.to_i,
      summary: @scan.summary || {},
      gcs_report_paths: report_paths,
      cost_data: @cost_logger.cost_data
    }
  end

  def report_paths
    @scan.reports.where(status: 'completed').map do |report|
      { format: report.format, gcs_path: report.gcs_path }
    end
  end

  def post_with_retries(payload)
    attempts = 0

    while attempts < MAX_RETRIES
      attempts += 1
      response = post_callback(payload)
      return true if response&.status&.between?(200, 299)

      Rails.logger.warn("[ScanCallbackService] Attempt #{attempts}/#{MAX_RETRIES} " \
                        "failed (status: #{response&.status})")
      sleep(RETRY_BASE_DELAY * attempts) if attempts < MAX_RETRIES
    end

    Rails.logger.error("[ScanCallbackService] Exhausted #{MAX_RETRIES} retries for #{callback_url}")
    false
  rescue StandardError => e
    Rails.logger.error("[ScanCallbackService] Failed: #{e.message}")
    false
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
