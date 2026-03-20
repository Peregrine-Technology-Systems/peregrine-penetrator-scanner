# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScanCostLogger do
  let(:target) { create(:target, name: 'Test App', urls: ['https://example.com']) }
  let(:scan) { create(:scan, target:, profile: 'standard', status: 'completed', started_at: 1.hour.ago, completed_at: Time.current) }
  let(:mock_bigquery) { instance_double(Google::Cloud::Bigquery::Project) }

  let(:bq_mocks) do
    dataset = instance_double(Google::Cloud::Bigquery::Dataset)
    table = instance_double(Google::Cloud::Bigquery::Table)
    response = instance_double(Google::Cloud::Bigquery::InsertResponse, success?: true)
    { dataset:, table:, response: }
  end

  before do
    allow(Google::Cloud::Bigquery).to receive(:new).and_return(mock_bigquery)
    stub_const('ENV', ENV.to_h.merge(
                        'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                        'SCAN_MODE' => 'dev'
                      ))
  end

  describe '#initialize' do
    it 'starts with zero counters' do
      logger = described_class.new(scan)
      data = logger.cost_data

      expect(data[:anthropic_tokens_used]).to eq(0)
      expect(data[:nvd_api_calls]).to eq(0)
      expect(data[:gcs_bytes_uploaded]).to eq(0)
    end
  end

  describe '#track_anthropic_tokens' do
    it 'accumulates token counts' do
      logger = described_class.new(scan)
      logger.track_anthropic_tokens(1500)
      logger.track_anthropic_tokens(2000)

      expect(logger.cost_data[:anthropic_tokens_used]).to eq(3500)
    end
  end

  describe '#track_nvd_api_call' do
    it 'increments API call counter' do
      logger = described_class.new(scan)
      logger.track_nvd_api_call
      logger.track_nvd_api_call
      logger.track_nvd_api_call

      expect(logger.cost_data[:nvd_api_calls]).to eq(3)
    end
  end

  describe '#track_gcs_upload' do
    it 'accumulates uploaded bytes' do
      logger = described_class.new(scan)
      logger.track_gcs_upload(1024)
      logger.track_gcs_upload(2048)

      expect(logger.cost_data[:gcs_bytes_uploaded]).to eq(3072)
    end
  end

  describe '#cost_data' do
    it 'returns complete cost data hash' do
      logger = described_class.new(scan)
      logger.track_anthropic_tokens(500)
      logger.track_nvd_api_call
      logger.track_gcs_upload(4096)

      data = logger.cost_data
      expect(data[:scan_id]).to eq(scan.id)
      expect(data[:vm_type]).to be_a(String)
      expect(data[:vm_runtime_seconds]).to be_a(Numeric)
      expect(data[:spot_instance]).to be(false).or be(true)
      expect(data[:anthropic_tokens_used]).to eq(500)
      expect(data[:nvd_api_calls]).to eq(1)
      expect(data[:gcs_bytes_uploaded]).to eq(4096)
      expect(data[:estimated_cost_usd]).to be_a(Numeric)
    end

    it 'reads VM type from GCE metadata env var' do
      stub_const('ENV', ENV.to_h.merge(
                          'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                          'VM_MACHINE_TYPE' => 'e2-standard-4'
                        ))
      logger = described_class.new(scan)

      expect(logger.cost_data[:vm_type]).to eq('e2-standard-4')
    end

    it 'defaults VM type when metadata unavailable' do
      logger = described_class.new(scan)

      expect(logger.cost_data[:vm_type]).to eq('unknown')
    end

    it 'calculates runtime from scan duration' do
      logger = described_class.new(scan)
      data = logger.cost_data

      expect(data[:vm_runtime_seconds]).to eq(scan.duration.to_i)
    end

    it 'detects spot instance from env var' do
      stub_const('ENV', ENV.to_h.merge(
                          'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                          'SPOT_INSTANCE' => 'true'
                        ))
      logger = described_class.new(scan)

      expect(logger.cost_data[:spot_instance]).to be(true)
    end
  end

  describe '#estimated_cost_usd' do
    it 'estimates cost based on tracked metrics' do
      logger = described_class.new(scan)
      logger.track_anthropic_tokens(10_000)
      logger.track_nvd_api_call

      cost = logger.cost_data[:estimated_cost_usd]
      expect(cost).to be > 0
    end
  end

  describe '#log_to_bigquery' do
    before do
      mocks = bq_mocks
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_costs').and_return(mocks[:table])
      allow(mocks[:table]).to receive(:insert).and_return(mocks[:response])
    end

    it 'inserts cost data row into BigQuery' do
      logger = described_class.new(scan)
      logger.track_anthropic_tokens(1000)

      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:scan_id]).to eq(scan.id)
        expect(row[:anthropic_tokens_used]).to eq(1000)
        expect(row[:created_at]).to be_a(Time)
        bq_mocks[:response]
      end

      expect(logger.log_to_bigquery).to be true
    end

    it 'creates table if it does not exist' do
      mocks = bq_mocks
      schema = double('schema') # rubocop:disable RSpec/VerifiedDoubles
      allow(schema).to receive_messages(string: nil, integer: nil, float: nil, boolean: nil, timestamp: nil)
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_costs').and_return(nil)
      allow(mocks[:dataset]).to receive(:create_table).with('scan_costs')
                                                      .and_yield(mocks[:table]).and_return(mocks[:table])
      allow(mocks[:table]).to receive_messages(schema:, insert: mocks[:response])

      logger = described_class.new(scan)
      expect(logger.log_to_bigquery).to be true
    end

    it 'creates dataset and table if neither exist' do
      mocks = bq_mocks
      schema = double('schema') # rubocop:disable RSpec/VerifiedDoubles
      allow(schema).to receive_messages(string: nil, integer: nil, float: nil, boolean: nil, timestamp: nil)
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(nil)
      allow(mock_bigquery).to receive(:create_dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_costs').and_return(nil)
      allow(mocks[:dataset]).to receive(:create_table).with('scan_costs')
                                                      .and_yield(mocks[:table]).and_return(mocks[:table])
      allow(mocks[:table]).to receive_messages(schema:, insert: mocks[:response])

      logger = described_class.new(scan)
      expect(logger.log_to_bigquery).to be true
    end

    it 'returns false and logs error on failure' do
      allow(mock_bigquery).to receive(:dataset).and_raise(StandardError, 'connection refused')

      logger = described_class.new(scan)
      expect(Rails.logger).to receive(:error).with(/ScanCostLogger.*connection refused/)
      expect(logger.log_to_bigquery).to be false
    end

    it 'skips logging when BigQuery is not enabled' do
      stub_const('ENV', ENV.to_h.except('GOOGLE_CLOUD_PROJECT'))

      logger = described_class.new(scan)
      expect(Google::Cloud::Bigquery).not_to receive(:new)
      expect(logger.log_to_bigquery).to be false
    end
  end
end
