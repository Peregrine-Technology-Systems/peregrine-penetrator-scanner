class ControlPlaneLoop
  INTERVAL = 30
  TICK_TIMEOUT = 10

  # rubocop:disable Metrics/ParameterLists -- the callback_url/callback_secret/job_id
  # trio is the HTTP-callback transport, removed at bus cutover (scanner#1005), which
  # drops this back under the limit; not worth an options-object churn pre-cutover.
  def initialize(scan_uuid:, job_id:, callback_url:, gcs_bucket:, callback_secret:,
                 identity: nil, publisher: Bus::Publisher.build)
    # rubocop:enable Metrics/ParameterLists
    @scan_uuid = scan_uuid
    @identity = identity
    @publisher = publisher
    @heartbeat = HeartbeatSender.new(
      callback_url:, scan_uuid:, job_id:, callback_secret:
    )
    @gcs_bucket = gcs_bucket
    @storage = StorageService.new if gcs_bucket.to_s.present?
    @mutex = Mutex.new
    @cancelled = false
    @running = false
    @progress = { current_tool: nil, progress_pct: 0, findings_count: 0, last_tool_started_at: nil }
  end

  def start
    safe_call('bus start') { publish_bus_start }
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
    progress = @mutex.synchronize { @progress.dup }
    safe_call('callback') { @heartbeat.send_heartbeat(status: 'running', **progress) }
    safe_call('GCS heartbeat') { write_gcs_heartbeat(progress) }
    safe_call('bus heartbeat') { publish_bus_heartbeat(progress) }
    safe_call('cancel check') { check_cancel }
  end

  def safe_call(label, &)
    Timeout.timeout(TICK_TIMEOUT, &)
  rescue Timeout::Error
    Penetrator.logger.warn("[ControlPlaneLoop] #{label} timed out after #{TICK_TIMEOUT}s — skipping")
  rescue StandardError => e
    Penetrator.logger.warn("[ControlPlaneLoop] #{label} error: #{e.message}")
  end

  def write_gcs_heartbeat(progress)
    return unless @storage

    payload = {
      scan_uuid: @scan_uuid,
      status: 'running',
      timestamp: Time.current.iso8601,
      **progress
    }
    # Enrich the durable fallback the orchestrator watchdog polls with bus-envelope
    # identity (transaction_id/environment/trace_id/tp_id). Additive + compacted:
    # nil until the launcher injects it, so this is inert today.
    payload.merge!(@identity.to_h.except(:scan_uuid)) if @identity
    @storage.upload_json("control/#{@scan_uuid}/heartbeat.json", payload)
  end

  # Publish liveness on the telemetry plane, keyed on the PROCESSOR (this scanner
  # instance), not the transaction it happens to be running (scanner#1127, org-wide
  # org-wide bus-grammar lock-in): `telemetry.tp.scanner.heartbeat.<tp-id>` —
  # this supersedes the flat `telemetry.penetrator.scan.heartbeat` subject
  # scanner#1052 previously ratified, which put the transaction class+stage in a
  # telemetry subject instead of the processor class; that shape is what the new
  # grammar's §3 rules out. In-flight transaction_id(s) still ride in the VALUE,
  # not the subject — the watchdog keys liveness by tp-id from the subject and
  # reads in_flight from the payload for correlation.
  # No-op when identity/tp_id is absent (off-bus) or the publisher is disabled;
  # the GCS heartbeat above is the durable fallback.
  def publish_bus_heartbeat(progress)
    return if @identity.nil? || @identity.tp_id.to_s.empty?

    subject = Peregrine::Bus::Subjects::Penetrator.scanner_heartbeat(@identity.tp_id)
    @publisher.publish(subject, {
                         tp_id: @identity.tp_id,
                         status: 'running',
                         in_flight: @identity.in_flight,
                         timestamp: Time.current.iso8601,
                         **progress
                       }, job_id: @identity.in_flight.first, status: 'running')
  end

  # One-shot liveness signal at successful startup (scanner#1127): seeds the
  # fleet-roster KV entry the heartbeat above renews, so the tp-monitor can tell
  # "never started" apart from "started, then went dark". No dedicated
  # `Subjects::Penetrator` helper exists for this yet — the grammar's generic
  # `telemetry.tp.<class>.<event>.<instance>` shape is built directly.
  def publish_bus_start
    return if @identity.nil? || @identity.tp_id.to_s.empty?

    subject = Peregrine::Bus::Subjects.telemetry('tp', 'scanner', 'start', @identity.tp_id)
    @publisher.publish(subject, {
                         tp_id: @identity.tp_id,
                         status: 'started',
                         in_flight: @identity.in_flight,
                         timestamp: Time.current.iso8601
                       }, job_id: @identity.in_flight.first, status: 'started')
  end

  def check_cancel
    return unless ControlFlagReader.enabled?

    return unless ControlFlagReader.new(gcs_bucket: @gcs_bucket, scan_uuid: @scan_uuid).cancelled?

    @mutex.synchronize { @cancelled = true }
    Penetrator.logger.info('[ControlPlaneLoop] Cancel signal detected')
  end
end
