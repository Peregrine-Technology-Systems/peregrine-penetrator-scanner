# frozen_string_literal: true

module Bus
  # Reports a scan.requested the worker refused to run (#1235): logs it loudly
  # and publishes scan.failed with the request's identity so the orchestrator
  # sees a failure. Silently dropping it, or worse scanning a made-up target,
  # would turn bad upstream input into a success-shaped result.
  class InvalidRequestReporter
    REASON = 'invalid_request'
    SUBJECT = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed')

    def initialize(publisher:)
      @publisher = publisher
    end

    def call(payload, problem)
      Penetrator.logger.error("[WorkerLoop] invalid scan.requested for job #{payload.job_id.inspect}: #{problem}")
      @publisher.publish(SUBJECT, body(payload, problem), job_id: payload.job_id, status: 'failed')
    end

    private

    def body(payload, problem)
      {
        job_id: payload.job_id,
        transaction_id: payload.transaction_id,
        environment: payload.environment,
        state: 'failed',
        reason: REASON,
        detail: problem,
        completed_at: Time.current.utc.iso8601
      }.compact
    end
  end
end
