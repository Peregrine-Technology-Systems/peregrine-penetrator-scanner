# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::Publisher do
  let(:subject_name) { Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'completed') }

  describe '.build' do
    it 'is disabled until the production substrate + keyset are wired (scanner#1009)' do
      expect(described_class.build.enabled?).to be(false)
    end
  end

  describe '.for' do
    it 'constructs an enabled publisher over an injected substrate + key provider' do
      publisher = described_class.for(substrate: Peregrine::Bus::MemorySubstrate.new,
                                      key_provider: keyset_for(subject_name))
      expect(publisher.enabled?).to be(true)
    end
  end

  describe '#publish (enabled, real adapter over MemorySubstrate)' do
    it 'seals the payload to the subject so it round-trips through the adapter' do
      publisher, adapter = bus_pair(subject_name)

      id = publisher.publish(subject_name, { 'state' => 'completed', 'scan_uuid' => 's1' }, job_id: 's1', status: 'completed')

      expect(id).to be_a(String)
      delivered = adapter.consume(subject_name).map { |pt| JSON.parse(pt) }
      expect(delivered).to eq([{ 'state' => 'completed', 'scan_uuid' => 's1' }])
    end

    it 'fails soft — a publish error never propagates (GCS fallback owns durability)' do
      publisher, = bus_pair(subject_name)
      allow(Penetrator.logger).to receive(:warn)
      # Publish to a subject with no key in the keyset → the adapter raises; we swallow.
      unkeyed = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed')

      result = nil
      expect { result = publisher.publish(unkeyed, {}) }.not_to raise_error
      expect(result).to be_nil
      expect(Penetrator.logger).to have_received(:warn).with(/publish failed/)
    end
  end

  describe '#publish (disabled)' do
    it 'drops the publish and returns nil' do
      publisher = described_class.new(nil)
      expect(publisher.publish(subject_name, { a: 1 })).to be_nil
    end

    it 'logs the dropped subject at debug' do
      allow(Penetrator.logger).to receive(:debug)
      described_class.new(nil).publish(subject_name, {})
      expect(Penetrator.logger).to have_received(:debug).with(/disabled — drop subject=#{Regexp.escape(subject_name)}/)
    end
  end
end
