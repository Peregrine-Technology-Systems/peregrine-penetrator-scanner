# frozen_string_literal: true

require 'sequel_helper'
require 'peregrine/bus/nats'

RSpec.describe Bus::ScanRequestConsumer do
  let(:subject_name) { Bus::ScanSubjects.requested }

  describe '#next_request (disabled)' do
    it 'returns nil when no adapter is wired' do
      expect(described_class.new(adapter: nil).next_request).to be_nil
    end
  end

  describe '#next_request (enabled, real adapter over MemorySubstrate)' do
    it 'decodes the oldest unconsumed scan.requested payload' do
      publisher, adapter = bus_pair(subject_name)
      publisher.publish(subject_name, { 'scan_uuid' => 's1', 'profile' => 'standard', 'urls' => ['https://a.example'] })

      request = described_class.new(adapter:).next_request

      expect(request).to eq('scan_uuid' => 's1', 'profile' => 'standard', 'urls' => ['https://a.example'])
    end

    it 'returns nil when the subject has no pending messages' do
      _publisher, adapter = bus_pair(subject_name)

      expect(described_class.new(adapter:).next_request).to be_nil
    end

    it 'acks and drops a smoke:true message rather than returning it (#1166)' do
      publisher, adapter = bus_pair(subject_name)
      publisher.publish(subject_name, { 'scan_uuid' => 's1', 'profile' => 'standard', 'smoke' => true })

      expect(described_class.new(adapter:).next_request).to be_nil
    end

    it 'returns a smoke:false message normally' do
      publisher, adapter = bus_pair(subject_name)
      publisher.publish(subject_name, { 'scan_uuid' => 's1', 'profile' => 'standard', 'smoke' => false })

      expect(described_class.new(adapter:).next_request).to eq('scan_uuid' => 's1', 'profile' => 'standard', 'smoke' => false)
    end
  end

  describe '#next_request (adapter raises)' do
    it 'is fail-soft — logs and returns nil rather than raising' do
      broken_adapter = instance_double(Peregrine::Bus::Adapter)
      allow(broken_adapter).to receive(:consume).and_raise(StandardError, 'boom')
      allow(Penetrator.logger).to receive(:warn)

      expect(described_class.new(adapter: broken_adapter).next_request).to be_nil
      expect(Penetrator.logger).to have_received(:warn).with(/scan\.requested consume failed/)
    end
  end

  describe '#next_request (backlog, #1208)' do
    it 'does not lose pending messages behind the one it returns' do
      publisher, adapter = bus_pair(subject_name)
      %w[s1 s2 s3].each { |id| publisher.publish(subject_name, { 'scan_uuid' => id }) }
      consumer = described_class.new(adapter:)

      taken = Array.new(3) { consumer.next_request&.fetch('scan_uuid') }

      expect(taken).to eq(%w[s1 s2 s3])
      expect(consumer.next_request).to be_nil
    end

    it 'acks and drops a malformed message instead of leaving it to redeliver forever' do
      adapter = instance_double(Peregrine::Bus::Adapter)
      allow(adapter).to receive(:consume).and_yield('not json')
      allow(Penetrator.logger).to receive(:warn)

      expect(described_class.new(adapter:).next_request).to be_nil
      expect(Penetrator.logger).to have_received(:warn).with(/malformed/)
    end
  end

  describe '#next_request (grammar env, #1243)' do
    def publish_on(subject, id)
      publisher, adapter = bus_pair(subject)
      publisher.publish(subject, { 'scan_uuid' => id })
      adapter
    end

    it 'reads the unmarked production subject in production' do
      allow(Penetrator).to receive(:env).and_return('production')
      adapter = publish_on('peregrine.data.task.penetrator.scan.requested', 'prod-1')

      expect(described_class.new(adapter:).next_request).to eq('scan_uuid' => 'prod-1')
    end

    it 'reads the staging-marked subject in staging, and never the production one' do
      allow(Penetrator).to receive(:env).and_return('staging')
      staged = publish_on('peregrine.staging.data.task.penetrator.scan.requested', 'stg-1')
      unmarked = publish_on('peregrine.data.task.penetrator.scan.requested', 'prod-1')

      expect(described_class.new(adapter: staged).next_request).to eq('scan_uuid' => 'stg-1')
      expect(described_class.new(adapter: unmarked).next_request).to be_nil
    end
  end

  describe '#next_request (loud substrate failures, #1203)' do
    # A missing durable or a denied bind is a deployment fault, not an empty queue:
    # swallowing it makes a worker that can never receive work look idle.
    {
      Peregrine::Bus::Nats::DurableNotFoundError => 'DurableNotFoundError',
      Peregrine::Bus::Nats::JetStreamDeniedError => 'JetStreamDeniedError'
    }.each do |error_class, name|
      it "re-raises #{name} rather than reading it as an empty queue" do
        adapter = instance_double(Peregrine::Bus::Adapter)
        allow(adapter).to receive(:consume).and_raise(error_class.allocate)

        expect { described_class.new(adapter:).next_request }.to raise_error(error_class)
      end
    end
  end
end
