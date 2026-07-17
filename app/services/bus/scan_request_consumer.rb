# frozen_string_literal: true

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
    def next_request
      return nil unless @adapter

      plaintext = @adapter.consume(SUBJECT).first
      return nil if plaintext.nil?

      JSON.parse(plaintext)
    rescue StandardError => e
      Penetrator.logger.warn("[Bus] scan.requested consume failed: #{e.message}")
      nil
    end
  end
end
