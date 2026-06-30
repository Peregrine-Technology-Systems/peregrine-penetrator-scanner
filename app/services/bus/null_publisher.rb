# frozen_string_literal: true

require_relative 'publisher'

module Bus
  # The default publisher until the bus-identity adapter is wired (scanner#1005).
  # Drops every publish (logs at debug so the intended subject/key is observable
  # without a substrate). Behaviourally inert: the durable GCS control/ writes are
  # the real completion + liveness signal while this is active, so the seam can land
  # in production ahead of the bus without changing any observable behaviour.
  class NullPublisher < Publisher
    def publish(subject:, payload:, key: nil) # rubocop:disable Lint/UnusedMethodArgument
      Penetrator.logger.debug("[Bus::NullPublisher] drop subject=#{subject} key=#{key || '-'}")
      nil
    end
  end
end
