class ControlPlaneLoop
  INTERVAL = 30
  TICK_TIMEOUT = 10

  def initialize(scan_uuid:, job_id:, callback_url:, gcs_bucket:, callback_secret:)
    @scan_uuid = scan_uuid
    @heartbeat = HeartbeatSender.new(
      callback_url:, scan_uuid:, job_id:, callback_secret:
    )
    @gcs_bucket = gcs_bucket
    @mutex = Mutex.new
    @cancelled = false
    @running = false
    @progress = { current_tool: nil, progress_pct: 0, findings_count: 0, last_tool_started_at: nil }
  end

  def start
    @running = true
    @thread = Thread.new { run_loop }
    self
  end

  def stop
    @running = false
    @thread&.join(5)
    @thread&.kill if @thread&.alive?
  end

  def cancelled?
    @mutex.synchronize { @cancelled }
  end

  def update_progress(current_tool: nil, progress_pct: nil, findings_count: nil, last_tool_started_at: nil)
    @mutex.synchronize do
      @progress[:current_tool] = current_tool if current_tool
      @progress[:progress_pct] = progress_pct if progress_pct
      @progress[:findings_count] = findings_count if findings_count
      @progress[:last_tool_started_at] = last_tool_started_at if last_tool_started_at
    end
  end

  private

  def run_loop
    tick # First heartbeat immediately (ack within 30s)
    while @running
      sleep(INTERVAL)
      tick if @running
    end
  rescue StandardError => e
    Penetrator.logger.error("[ControlPlaneLoop] Loop crashed: #{e.message}")
  end

  def tick
    Timeout.timeout(TICK_TIMEOUT) do
      progress = @mutex.synchronize { @progress.dup }
      @heartbeat.send_heartbeat(status: 'running', **progress)
      check_cancel
    end
  rescue Timeout::Error
    Penetrator.logger.warn("[ControlPlaneLoop] Tick timed out after #{TICK_TIMEOUT}s — skipping")
  rescue StandardError => e
    Penetrator.logger.warn("[ControlPlaneLoop] Tick error: #{e.message}")
  end

  def check_cancel
    return unless ControlFlagReader.enabled?

    if ControlFlagReader.new(gcs_bucket: @gcs_bucket, scan_uuid: @scan_uuid).cancelled?
      @mutex.synchronize { @cancelled = true }
      Penetrator.logger.info('[ControlPlaneLoop] Cancel signal detected')
    end
  rescue StandardError => e
    Penetrator.logger.warn("[ControlPlaneLoop] Cancel check failed: #{e.message}")
  end
end
