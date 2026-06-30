# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::Publisher do
  describe '.build' do
    it 'returns a NullPublisher until the bus-identity adapter is wired (scanner#1005)' do
      expect(described_class.build).to be_a(Bus::NullPublisher)
    end
  end

  describe '#publish (base interface)' do
    it 'is abstract — a bare Publisher cannot publish' do
      expect { described_class.new.publish(subject: 'x', payload: {}) }
        .to raise_error(NotImplementedError, /Publisher#publish/)
    end
  end

  describe 'the Publisher contract (via a recording reference impl)' do
    subject(:publisher) { recording_class.new }

    # A minimal subclass proving the interface is satisfiable and documenting the
    # publish contract the real adapter must honour: it records (subject, payload, key).
    let(:recording_class) do
      Class.new(described_class) do
        attr_reader :sent

        def initialize
          @sent = []
          super
        end

        def publish(subject:, payload:, key: nil)
          @sent << { subject:, payload:, key: }
        end
      end
    end

    it 'records subject, payload and key' do
      publisher.publish(subject: 'data.task.penetrator.scan.completed', payload: { a: 1 }, key: 'tp-1')
      expect(publisher.sent).to eq([{ subject: 'data.task.penetrator.scan.completed', payload: { a: 1 }, key: 'tp-1' }])
    end

    it 'treats key as optional' do
      publisher.publish(subject: 's', payload: {})
      expect(publisher.sent.first[:key]).to be_nil
    end
  end

  describe Bus::NullPublisher do
    subject(:publisher) { described_class.new }

    it 'drops the publish and returns nil (inert until the adapter is wired)' do
      expect(publisher.publish(subject: 'data.task.penetrator.scan.completed', payload: { a: 1 }, key: 'tp-1')).to be_nil
    end

    it 'logs the dropped subject + key at debug for observability' do
      allow(Penetrator.logger).to receive(:debug)
      publisher.publish(subject: 'telemetry.tp.scanner.heartbeat.tp-1', payload: {}, key: 'tp-1')
      expect(Penetrator.logger).to have_received(:debug).with(/drop subject=telemetry.tp.scanner.heartbeat.tp-1 key=tp-1/)
    end

    it 'renders a missing key as a dash in the log line' do
      allow(Penetrator.logger).to receive(:debug)
      publisher.publish(subject: 's', payload: {})
      expect(Penetrator.logger).to have_received(:debug).with(/key=-/)
    end
  end
end
