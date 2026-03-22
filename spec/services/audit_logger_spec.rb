# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditLogger do
  subject(:audit) { described_class.new }

  let(:target) { create(:target, name: 'Test App') }
  let(:scan) { create(:scan, :completed, target:) }

  before do
    allow(Rails.logger).to receive(:info)
    create(:finding, scan:, duplicate: false, fingerprint: SecureRandom.hex(32))
  end

  describe '#log' do
    it 'outputs structured JSON to logger' do
      audit.log(action: 'test_action', scan_id: 'scan-123', extra: 'value')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['event']).to eq('audit')
        expect(parsed['action']).to eq('test_action')
        expect(parsed['scan_id']).to eq('scan-123')
        expect(parsed['extra']).to eq('value')
      end
    end

    it 'includes event_id and timestamp' do
      audit.log(action: 'test', scan_id: 'x')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['event_id']).to match(/\A[0-9a-f-]{36}\z/)
        expect(parsed['timestamp']).to match(/\A\d{4}-\d{2}-\d{2}T/)
      end
    end

    it 'includes actor identity' do
      audit.log(action: 'test', scan_id: 'x')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['actor']).to be_a(Hash)
        expect(parsed['actor']['scan_mode']).to eq('dev')
      end
    end

    it 'includes schema_version' do
      audit.log(action: 'test', scan_id: 'x')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['schema_version']).to eq('1.0')
      end
    end
  end

  describe '#scan_started' do
    it 'logs scan_started with target and profile' do
      audit.scan_started(scan)

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['action']).to eq('scan_started')
        expect(parsed['target_name']).to eq('Test App')
        expect(parsed['profile']).to eq('standard')
      end
    end
  end

  describe '#scan_completed' do
    it 'logs scan_completed with finding count and GCS path' do
      audit.scan_completed(scan, gcs_path: 'scan-results/t/s/scan_results.json')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['action']).to eq('scan_completed')
        expect(parsed['finding_count']).to eq(1)
        expect(parsed['gcs_output_path']).to eq('scan-results/t/s/scan_results.json')
        expect(parsed['duration_seconds']).to be_a(Integer)
      end
    end
  end

  describe '#scan_failed' do
    it 'logs scan_failed with error' do
      audit.scan_failed(scan, error: 'Connection timeout')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['action']).to eq('scan_failed')
        expect(parsed['error']).to eq('Connection timeout')
        expect(parsed['status']).to eq('failed')
      end
    end

    it 'truncates long error messages' do
      audit.scan_failed(scan, error: 'x' * 1000)

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['error'].length).to be <= 500
      end
    end
  end

  describe '#json_exported' do
    it 'logs json_exported with GCS path and finding count' do
      audit.json_exported(scan, gcs_path: 'scan-results/path.json')

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['action']).to eq('json_exported')
        expect(parsed['gcs_output_path']).to eq('scan-results/path.json')
        expect(parsed['finding_count']).to eq(1)
      end
    end
  end

  describe '#bq_loaded' do
    it 'logs bq_loaded with row count' do
      audit.bq_loaded(scan, rows_logged: 42)

      expect(Rails.logger).to have_received(:info) do |msg|
        parsed = JSON.parse(msg)
        expect(parsed['action']).to eq('bq_loaded')
        expect(parsed['rows_logged']).to eq(42)
      end
    end
  end
end
