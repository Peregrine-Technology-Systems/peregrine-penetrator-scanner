# frozen_string_literal: true

module Bus
  # The persistent poll-loop worker (scanner#1171, matching the shared
  # analyzer#243/tp-monitor#733 convention): boots, polls its own
  # scan.requested subject, runs one job per pull via ScanJobRunner, and after
  # `drain_idle_seconds` of no new work emits a worker-level `exiting`
  # telemetry event and returns — letting the process exit 0 cleanly, ahead of
  # tp-monitor's own MIG resize-to-0 backstop.
  #
  # Single-threaded, synchronous: SIGTERM sets a flag (`drain!`) checked
  # between pulls, never mid-job — the in-flight scan always finishes.
  class WorkerLoop
    POLL_INTERVAL_SECONDS = 5
    # 300 (tp-monitor prod drain_idle_seconds) + 180 (cooldown_scale_down_seconds)
    # — the same number analyzer#243 landed on, confirmed against tp-monitor
    # directly: exit sooner and the worker can self-terminate before
    # tp-monitor's resize-to-0 catches up, leaving idle-VM churn.
    DEFAULT_DRAIN_IDLE_SECONDS = 480

    def initialize(consumer: ScanRequestConsumer.new, publisher: Publisher.build,
                   drain_idle_seconds: ENV.fetch('SCANNER_DRAIN_IDLE_SECONDS', DEFAULT_DRAIN_IDLE_SECONDS).to_i,
                   poll_interval: POLL_INTERVAL_SECONDS, clock: -> { Time.now })
      @consumer = consumer
      @publisher = publisher
      @drain_idle_seconds = drain_idle_seconds
      @poll_interval = poll_interval
      @clock = clock
      @draining = false
    end

    # Called from a SIGTERM trap — never interrupts an in-flight job, only
    # stops the loop from starting its NEXT pull.
    def drain!
      @draining = true
    end

    def run
      last_activity = @clock.call

      until @draining
        bus_request = @consumer.next_request
        if bus_request
          run_job(bus_request)
          last_activity = @clock.call
          next
        end

        break if idle_timed_out?(last_activity)

        sleep(@poll_interval)
      end

      publish_exiting
    end

    private

    def idle_timed_out?(last_activity)
      (@clock.call - last_activity) >= @drain_idle_seconds
    end

    def run_job(bus_request)
      payload = ScanRequestPayload.new(bus_request)
      ENV['SCAN_UUID'] = payload.job_id
      ENV['TRANSACTION_ID'] = payload.transaction_id
      ENV['ENVIRONMENT'] = payload.environment

      ScanJobRunner.new(
        profile: payload.profile || 'standard',
        target_name: payload.target_name || 'Default Target',
        target_urls: payload.target_urls || ['http://localhost:8080']
      ).call
    rescue StandardError => e
      Penetrator.logger.error("[WorkerLoop] job failed: #{e.message}")
    ensure
      ENV.delete('SCAN_UUID')
      ENV.delete('TRANSACTION_ID')
      ENV.delete('ENVIRONMENT')
    end

    def publish_exiting
      tp_id = InstanceMetadata.tp_id
      return if tp_id.to_s.empty?

      subject = Peregrine::Bus::Subjects.telemetry('tp', 'scanner', 'exiting', tp_id)
      @publisher.publish(subject, {
                           tp_id: tp_id,
                           status: 'exiting',
                           timestamp: Time.current.iso8601
                         }, status: 'exiting')
    end
  end
end
