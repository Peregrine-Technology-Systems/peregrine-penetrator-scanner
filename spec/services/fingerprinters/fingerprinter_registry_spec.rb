# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::FingerprinterRegistry do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, target:) }
  let(:registry) { described_class.new(scan) }

  before { described_class.reset! }
  after { described_class.reset! }

  def anonymous_detector(cms:, confidence:)
    Class.new(Fingerprinters::FingerprinterBase) do
      define_method(:cms_name) { cms }
      define_method(:detect) { { cms:, confidence:, components: [] } }
    end
  end

  describe '.detectors' do
    it 'defaults to just the GenericFingerprinter' do
      expect(described_class.detectors).to eq([Fingerprinters::GenericFingerprinter])
    end
  end

  describe '.register' do
    it 'prepends a detector ahead of the generic fallback' do
      detector_class = anonymous_detector(cms: 'foo', confidence: 0.9)
      described_class.register(detector_class)

      expect(described_class.detectors.first).to eq(detector_class)
      expect(described_class.detectors.last).to eq(Fingerprinters::GenericFingerprinter)
    end

    it 'is idempotent — registering the same detector twice leaves one copy' do
      detector_class = anonymous_detector(cms: 'foo', confidence: 0.9)
      described_class.register(detector_class)
      described_class.register(detector_class)

      expect(described_class.detectors.count(detector_class)).to eq(1)
    end
  end

  describe '#detect' do
    it 'returns the first detector result that meets the confidence threshold' do
      described_class.register(anonymous_detector(cms: 'matched', confidence: 0.95))

      result = registry.detect
      expect(result[:cms]).to eq('matched')
      expect(result[:confidence]).to eq(0.95)
      expect(result[:detected_at]).to be_present
    end

    it 'falls back to GenericFingerprinter when no detector meets the threshold' do
      described_class.register(anonymous_detector(cms: 'barely', confidence: 0.1))

      result = registry.detect
      expect(result[:cms]).to eq('unknown')
      expect(result[:confidence]).to eq(0.0)
    end

    it 'skips detectors that raise, then tries the next one' do
      raising = Class.new(Fingerprinters::FingerprinterBase) do
        def cms_name = 'raising'
        def detect = raise('boom')
      end
      matching = anonymous_detector(cms: 'matched', confidence: 0.9)

      described_class.register(matching)
      described_class.register(raising)

      expect(Penetrator.logger).to receive(:warn).with(/raised: boom/).at_least(:once)
      result = registry.detect
      expect(result[:cms]).to eq('matched')
    end

    it 'does not abort when every registered detector raises' do
      raising = Class.new(Fingerprinters::FingerprinterBase) do
        def cms_name = 'raising'
        def detect = raise('boom')
      end
      described_class.register(raising)

      allow(Penetrator.logger).to receive(:warn)
      expect { registry.detect }.not_to raise_error
    end
  end
end
