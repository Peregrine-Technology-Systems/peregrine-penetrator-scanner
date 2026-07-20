# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::ScanRequestConsumer do
  let(:subject_name) { Bus::ScanRequestConsumer::SUBJECT }

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
end
