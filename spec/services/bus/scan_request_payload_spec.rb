# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::ScanRequestPayload do
  describe 'with a real orchestrator payload' do
    let(:raw) do
      {
        'job_id' => 'job-1',
        'status' => 'scanning',
        'transaction_id' => 'txn-1',
        'environment' => 'production',
        'smoke' => false,
        'target_url' => 'https://example.com/app',
        'profile' => 'standard'
      }
    end
    let(:payload) { described_class.new(raw) }

    it 'reads job_id, transaction_id, environment, and profile verbatim' do
      expect(payload.job_id).to eq('job-1')
      expect(payload.transaction_id).to eq('txn-1')
      expect(payload.environment).to eq('production')
      expect(payload.profile).to eq('standard')
    end

    it 'wraps the singular target_url into a single-element target_urls array' do
      expect(payload.target_urls).to eq(['https://example.com/app'])
    end

    it 'derives target_name from the URL host — no target_name field exists in the real contract' do
      expect(payload.target_name).to eq('example.com')
    end
  end

  describe 'with a nil payload (disabled/off-bus)' do
    let(:payload) { described_class.new(nil) }

    it 'degrades every field to nil rather than raising' do
      expect(payload.job_id).to be_nil
      expect(payload.transaction_id).to be_nil
      expect(payload.environment).to be_nil
      expect(payload.profile).to be_nil
      expect(payload.target_name).to be_nil
      expect(payload.target_urls).to be_nil
    end
  end

  describe 'with a malformed target_url' do
    let(:payload) { described_class.new({ 'target_url' => ':::not a uri' }) }

    it 'target_name degrades to nil rather than raising' do
      expect(payload.target_name).to be_nil
    end

    it 'target_urls still wraps the raw string (URI validity is not target_urls\' concern)' do
      expect(payload.target_urls).to eq([':::not a uri'])
    end
  end
end
