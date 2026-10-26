# frozen_string_literal: true

require 'peregrine/bus/nats/errors'

module Bus
  # Consumer-side half of the scanner's Transaction Processor conversion
  # (scanner#1106, restored by #1152 after PR #1117 removed it against a
  # since-reversed decision).
  #
  # tp-monitor#733 reversed the interim launcher-consumes-and-hands-off model
  # that #1117 was built against: the canonical worker contract is now
  # "the worker pulls, processes, and acks its own subject directly" —
  # tp-monitor only counts backlog and resizes the MIG, it never brokers a
  # message on a worker's behalf. So the VM is back to pulling its own
  # `scan.requested` claim-check directly, exactly as this class did before
  # #1117 deleted it.
  #
  # Disabled mode mirrors Bus::Publisher — nil adapter (no substrate/keyset
  # wired) means no bus traffic exists to consume, so `next_request` returns
  # nil and bin/scan falls back to its ENV-injected launch parameters (VM
  # metadata → env, the pre-bus path).
  class ScanRequestConsumer
    SUBJECT = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'requested')

    def initialize(adapter: AdapterEnv.adapter)
      @adapter = adapter
    end

    # The oldest unconsumed scan.requested payload (a Hash), or nil when disabled,
    # empty, or the adapter refuses every pending message (malformed/undecryptable
    # — refuse-don't-deliver, never raised to the caller).
    #
    # `smoke: true` messages are ack'd (via Adapter#consume's ack-regardless
    # semantics) and DROPPED here rather than returned — per the orchestrator's
    # payload contract (scanner#1164), `smoke` is a message-provenance marker
    # meaning "synthetic transport-probe, discard without acting", orthogonal to
    # `profile`. A real observer must never scan a target for a message meant to
    # be discarded. Expected to be rare-to-never on this subject in practice
    # (today's only smoke:true producer publishes on a different, terminal
    # subject) — this is belt-and-suspenders, not a live path.
    def next_request
      return nil unless @adapter

      chosen = nil
      @adapter.consume(SUBJECT) do |plaintext|
        # One request per call. The transport hands over a whole batch and the
        # core acks anything the block does not :nack, so every extra is
        # requeued for the next call instead of being acked and lost (#1208).
        next :nack if chosen

        chosen = decode(plaintext)
        nil
      end
      chosen
    rescue Peregrine::Bus::Nats::DurableNotFoundError, Peregrine::Bus::Nats::JetStreamDeniedError
      # A missing durable or a denied bind is a deployment fault, not an empty
      # queue; reading it as "nothing to do" hides a worker that can never
      # receive work (#1203).
      raise
    rescue StandardError => e
      Penetrator.logger.warn("[Bus] scan.requested consume failed: #{e.message}")
      nil
    end

    private

    # The parsed payload, or nil for a message that must be dropped (acked):
    # malformed JSON would otherwise redeliver forever, and a smoke:true marker
    # means "discard without acting".
    def decode(plaintext)
      payload = JSON.parse(plaintext)
      if payload['smoke'] == true
        Penetrator.logger.info('[Bus] scan.requested dropped — smoke:true (provenance marker, not a real scan)')
        return nil
      end

      payload
    rescue JSON::ParserError => e
      Penetrator.logger.warn("[Bus] scan.requested dropped — malformed payload: #{e.message}")
      nil
    end
  end
end
