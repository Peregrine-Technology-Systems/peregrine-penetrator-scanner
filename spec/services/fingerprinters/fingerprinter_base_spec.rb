# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::FingerprinterBase do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, target:) }

  describe '#detect' do
    it 'raises NotImplementedError in the base class' do
      expect { described_class.new(scan).detect }.to raise_error(NotImplementedError)
    end
  end

  describe '#cms_name' do
    it 'raises NotImplementedError in the base class' do
      expect { described_class.new(scan).cms_name }.to raise_error(NotImplementedError)
    end
  end

  describe 'HTTP helpers' do
    let(:detector_class) do
      Class.new(described_class) do
        def cms_name = 'test'
        def detect = empty_result
      end
    end
    let(:detector) { detector_class.new(scan) }

    before do
      # Expose the protected HTTP helpers on this anonymous subclass for direct testing.
      detector_class.send(:public, :http_get, :http_head)
    end

    it 'returns the Faraday response on success' do
      stub_request(:get, 'https://example.com/probe').to_return(status: 200, body: 'ok')
      expect(detector.http_get('https://example.com/probe').status).to eq(200)
    end

    it 'returns nil and logs on failure' do
      stub_request(:head, 'https://example.com/probe').to_raise(Faraday::ConnectionFailed.new('refused'))
      expect(Penetrator.logger).to receive(:debug).with(/HEAD.*failed/)
      expect(detector.http_head('https://example.com/probe')).to be_nil
    end
  end
end
