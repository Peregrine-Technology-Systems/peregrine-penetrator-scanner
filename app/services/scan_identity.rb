# frozen_string_literal: true

# Bus-envelope identity for a running scan (scanner#1005). Gathers the immutable
# `transaction_id` (the orchestrator's idempotency key), `scan_uuid`, `environment`,
# `trace_id` (trace/correlation), and `tp_id` (this scanner instance) from the
# launch ENV + instance metadata.
#
# Fail-safe by design: off-bus (local dev, CI, the current pre-bus production path
# where the launcher does not yet inject these) every field degrades to a sentinel
# or is omitted — a scan must never fail for missing identity. The launcher injects
# TRANSACTION_ID / ENVIRONMENT / TRACE_ID once the bus path is live; until then
# `to_h` simply omits the absent keys, so threading this into the durable GCS
# control/ writes is additive and inert today.
class ScanIdentity
  attr_reader :scan_uuid, :transaction_id, :environment, :trace_id, :tp_id

  def self.from_env(scan_id:)
    new(
      scan_uuid: present_or(ENV.fetch('SCAN_UUID', nil), scan_id.to_s),
      transaction_id: present_or(ENV.fetch('TRANSACTION_ID', nil), nil),
      environment: present_or(ENV.fetch('ENVIRONMENT', nil), Penetrator.env),
      trace_id: present_or(ENV.fetch('TRACE_ID', nil), nil),
      tp_id: InstanceMetadata.tp_id
    )
  end

  def initialize(scan_uuid:, transaction_id:, environment:, trace_id:, tp_id:)
    @scan_uuid = scan_uuid
    @transaction_id = transaction_id
    @environment = environment
    @trace_id = trace_id
    @tp_id = tp_id
  end

  # Identity fields for embedding in GCS control/ payloads and (later) bus
  # envelopes. Nil fields are dropped so absent identity adds no empty keys.
  def to_h
    {
      scan_uuid:,
      transaction_id:,
      environment:,
      trace_id:,
      tp_id:
    }.compact
  end

  # In-flight transaction id(s) for the heartbeat *value* (keyed by tp-id alone, per
  # the ratified bus scheme). A list because the contract carries the work an
  # instance is doing, not a single scan; today a scanner VM runs one scan, so it is
  # 0 or 1 entry.
  def in_flight
    [transaction_id].compact
  end

  def self.present_or(value, fallback)
    value.to_s.empty? ? fallback : value
  end
  private_class_method :present_or
end
