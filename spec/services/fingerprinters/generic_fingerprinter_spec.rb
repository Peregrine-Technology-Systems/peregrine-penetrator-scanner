# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::GenericFingerprinter do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, target:) }
  let(:detector) { described_class.new(scan) }

  describe '#cms_name' do
    it 'returns unknown' do
      expect(detector.cms_name).to eq('unknown')
    end
  end

  describe '#detect' do
    it 'returns an empty result with cms unknown and zero confidence' do
      expect(detector.detect).to eq(cms: 'unknown', confidence: 0.0, components: [])
    end
  end
end
