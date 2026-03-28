class HeartbeatSender
  def initialize(reporter_base_url:, scan_uuid:, job_id:, callback_secret:)
    @url = "#{reporter_base_url}/callbacks/heartbeat"
    @scan_uuid = scan_uuid
    @job_id = job_id
    @secret = callback_secret
    @connection = build_connection
  end

  def send_heartbeat(status: 'running', progress_pct: 0, current_tool: nil, findings_count: 0, last_tool_started_at: nil)
    payload = {
      job_id: @job_id,
      scan_uuid: @scan_uuid,
      status:,
      progress_pct:,
      current_tool:,
      findings_count:,
      last_tool_started_at:,
      timestamp: Time.current.iso8601
    }.compact

    @connection.post(@url) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{@secret}"
      req.body = payload.to_json
    end
  rescue StandardError => e
    Penetrator.logger.warn("[HeartbeatSender] Failed: #{e.message}")
  end

  def self.enabled?
    ENV.fetch('REPORTER_BASE_URL', nil).present?
  end

  private

  def build_connection
    Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 8
      f.options.open_timeout = 5
    end
  end
end
