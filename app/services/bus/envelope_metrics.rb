# frozen_string_literal: true

module Bus
  # Counts envelope opens by wire version for the envelope v2 cutover (arch#1180, #1229).
  # The bus library calls `metrics.call(name)` on each successful open with
  # `envelope_v1_opened` / `envelope_v2_opened`; this keeps
  # `peregrine_bus_envelope_opened_total{version, consumer}` so the cutover's end
  # condition ("no v1 opens remain") is measurable. Both series are always reported,
  # a zero included, because an absent series and a zero count read the same on a
  # dashboard and mean opposite things.
  #
  # This is the counter only. The scanner is an ephemeral worker with no HTTP server,
  # so nothing serves `to_prometheus` yet (#1229); the scrape registration the bus
  # pattern calls for is not live. Until an exporter exists the series is readable
  # in process and through the logged summary, not on a scrape endpoint.
  class EnvelopeMetrics
    NAME = 'peregrine_bus_envelope_opened_total'
    EVENTS = { 'envelope_v1_opened' => 'v1', 'envelope_v2_opened' => 'v2' }.freeze

    def self.instance
      @instance ||= new
    end

    def initialize(consumer: 'penetrator-scanner')
      @consumer = consumer
      @counts = EVENTS.values.to_h { |version| [version, 0] }
      @lock = Mutex.new
    end

    def call(event)
      version = EVENTS[event]
      return unless version

      @lock.synchronize { @counts[version] += 1 }
    end

    def count(version)
      @lock.synchronize { @counts.fetch(version) }
    end

    def to_prometheus
      series = @lock.synchronize { @counts.dup }.map do |version, n|
        %(#{NAME}{version="#{version}",consumer="#{@consumer}"} #{n})
      end
      ["# TYPE #{NAME} counter", *series].join("\n") << "\n"
    end
  end
end
