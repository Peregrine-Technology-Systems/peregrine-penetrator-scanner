class HeartbeatSender
  def initialize(callback_url:, scan_uuid:, job_id:, callback_secret:)
    @url = derive_heartbeat_url(callback_url)
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

    # No CALLBACK_URL configured (e.g. the CI smoke launched via trigger-scan.sh,
    # which sets none) → nothing to POST to. Guard against POSTing to a derived
    # empty/host-less URL, which used to log "connection refused for nil port 80"
    # noise once #830 removed the smoke-test stub. enabled?/CALLBACK_URL presence
    # is the real gate; this is its instance-level counterpart.
    return if @url.to_s.empty?

    @connection.post(@url) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{@secret}"
      req.body = payload.to_json
    end
  rescue StandardError => e
    Penetrator.logger.warn("[HeartbeatSender] Failed: #{e.message}")
  end

  def self.enabled?
    ENV.fetch('CALLBACK_URL', nil).present?
  end

  private

  def derive_heartbeat_url(callback_url)
    "#{callback_url.chomp('/')}/heartbeat"
  rescue StandardError
    ''
  end

  def build_connection
    Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.options.timeout = 8
      f.options.open_timeout = 5
    end
  end
end
