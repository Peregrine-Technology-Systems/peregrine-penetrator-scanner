# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe DataRetentionPurger do
  let(:mock_bigquery) { instance_double(Google::Cloud::Bigquery::Project) }
  let(:mock_dataset) { instance_double(Google::Cloud::Bigquery::Dataset) }
  let(:mock_table) { instance_double(Google::Cloud::Bigquery::Table) }

  before do
    allow(Google::Cloud::Bigquery).to receive(:new).and_return(mock_bigquery)
    stub_const('ENV', ENV.to_h.merge('SCAN_MODE' => 'dev'))
  end

  describe '#purge_all' do
    let(:query_result) { instance_double(Google::Cloud::Bigquery::Data, total: 42) }

    before do
      allow(mock_bigquery).to receive(:dataset).and_return(mock_dataset)
      allow(mock_dataset).to receive(:table).and_return(mock_table)
      allow(mock_bigquery).to receive(:query).and_return(query_result)
    end

    it 'purges all configured tables' do
      results = described_class.new.purge_all

      expect(results.keys).to include('scan_findings_dev', 'scan_metadata_dev', 'scan_costs_dev', 'penetrator_events')
    end

    it 'returns success with row counts' do
      results = described_class.new.purge_all

      results.each_value do |result|
        expect(result[:success]).to be true
        expect(result[:rows_deleted]).to eq(42)
      end
    end

    it 'uses DELETE query with 18-month cutoff' do
      expect(mock_bigquery).to receive(:query).with(/DELETE FROM.*WHERE.*scan_date </).at_least(:once).and_return(query_result)

      described_class.new.purge_all
    end

    it 'logs the purge event' do
      allow(Penetrator.logger).to receive(:info)
      described_class.new.purge_all
      expect(Penetrator.logger).to have_received(:info).with(/data_retention_purge/).once
    end
  end

  describe '#purge_all when table does not exist' do
    before do
      allow(mock_bigquery).to receive(:dataset).and_return(mock_dataset)
      allow(mock_dataset).to receive(:table).and_return(nil)
    end

    it 'returns zero rows deleted without error' do
      results = described_class.new.purge_all

      results.each_value do |result|
        expect(result[:success]).to be true
        expect(result[:rows_deleted]).to eq(0)
      end
    end
  end

  describe '#purge_all when BQ fails' do
    before do
      allow(mock_bigquery).to receive(:dataset).and_raise(StandardError, 'BQ unavailable')
    end

    it 'returns failure without raising' do
      results = described_class.new.purge_all

      results.each_value do |result|
        expect(result[:success]).to be false
        expect(result[:error]).to include('BQ unavailable')
      end
    end
  end

  describe '#preview_all' do
    let(:count_result) do
      [{ cnt: 15 }]
    end

    before do
      allow(mock_bigquery).to receive(:dataset).and_return(mock_dataset)
      allow(mock_dataset).to receive(:table).and_return(mock_table)
      allow(mock_bigquery).to receive(:query).and_return(count_result)
    end

    it 'returns counts for each table' do
      counts = described_class.new.preview_all

      counts.each_value do |count|
        expect(count).to eq(15)
      end
    end
  end

  describe 'RETENTION_MONTHS' do
    it 'is 18 months' do
      expect(described_class::RETENTION_MONTHS).to eq(18)
    end
  end
end
