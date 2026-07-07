# frozen_string_literal: true

module Bus
  # Consumer-side half of the scanner's Transaction Processor conversion
  # (scanner#1106): pulls the next `scan.requested` claim-check off the
  # competing-consumer subscription and returns its decoded payload.
  #
  # Disabled mode mirrors Bus::Publisher — nil adapter (no substrate/keyset wired)
  # means no bus traffic exists to consume, so `next_request` returns nil and
  # bin/scan falls back to its existing ENV-injected launch parameters (VM
  # metadata → env, the pre-bus path). Once infra wires a scan-launcher that
  # publishes `scan.requested` at `.stage`, this starts returning real requests
  # without any scanner-side flag flip.
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
