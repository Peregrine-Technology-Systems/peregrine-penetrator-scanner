require 'rails_helper'

RSpec.describe BigQueryLogger do
  let(:target) { create(:target, name: 'Test App', urls: ['https://example.com']) }
  let(:scan) { create(:scan, target:, profile: 'quick', status: 'completed') }
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
    it 'sets table name based on SCAN_MODE' do
      expect(described_class.new.table_name).to eq('scan_findings_dev')
    end

    it 'defaults to dev table when SCAN_MODE not set' do
      stub_const('ENV', ENV.to_h.merge(
        'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev'
      ).except('SCAN_MODE'))
      expect(described_class.new.table_name).to eq('scan_findings_dev')
    end

    it 'uses staging table for staging mode' do
      stub_const('ENV', ENV.to_h.merge(
                          'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                          'SCAN_MODE' => 'staging'
                        ))
      expect(described_class.new.table_name).to eq('scan_findings_staging')
    end

    it 'uses production table for production mode' do
      stub_const('ENV', ENV.to_h.merge(
                          'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                          'SCAN_MODE' => 'production'
                        ))
      expect(described_class.new.table_name).to eq('scan_findings_production')
    end
  end

  describe '#log_findings' do
    let(:finding) do
      create(:finding, scan:, severity: 'high', title: 'XSS in login',
                       source_tool: 'zap', url: 'https://example.com/login',
                       cwe_id: 'CWE-79', fingerprint: SecureRandom.hex(32))
    end

    before do
      finding
      mocks = bq_mocks
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_findings_dev').and_return(mocks[:table])
      allow(mocks[:table]).to receive(:insert).and_return(mocks[:response])
    end

    it 'inserts finding data into BigQuery' do
      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:fingerprint]).to eq(finding.fingerprint)
        expect(row[:site]).to eq('https://example.com')
        expect(row[:severity]).to eq('high')
        expect(row[:title]).to eq('XSS in login')
        expect(row[:tool]).to eq('zap')
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end

    it 'includes scan metadata in each row' do
      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:scan_id]).to eq(scan.id)
        expect(row[:scan_date]).to be_a(Time)
        expect(row[:profile]).to eq('quick')
        expect(row[:cwe_id]).to eq('CWE-79')
        expect(row[:url]).to eq('https://example.com/login')
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end

    it 'leaves ticket columns nil when no ticket data' do
      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:ticket_system]).to be_nil
        expect(row[:ticket_ref]).to be_nil
        expect(row[:ticket_status]).to be_nil
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end

    it 'populates ticket columns from finding evidence' do
      finding.update!(evidence: {
                        'ticket_system' => 'github',
                        'ticket_ref' => 'org/repo#42',
                        'ticket_pushed_at' => '2026-03-20T04:00:00Z'
                      })

      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:ticket_system]).to eq('github')
        expect(row[:ticket_ref]).to eq('org/repo#42')
        expect(row[:ticket_status]).to eq('open')
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end

    it 'excludes duplicate findings' do
      create(:finding, scan:, severity: 'medium', title: 'Missing headers',
                       source_tool: 'nuclei', fingerprint: SecureRandom.hex(32))
      create(:finding, scan:, severity: 'low', title: 'Duplicate',
                       source_tool: 'zap', fingerprint: SecureRandom.hex(32),
                       duplicate: true)

      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        expect(rows.length).to eq(2)
        expect(rows.pluck(:title)).not_to include('Duplicate')
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end

    it 'returns the count of logged findings' do
      expect(described_class.new.log_findings(scan)).to eq(1)
    end

    it 'truncates evidence to 1000 characters' do
      finding.update!(evidence: { 'raw' => 'x' * 2000 })

      table = bq_mocks[:table]
      allow(table).to receive(:insert) do |rows|
        expect(rows.first[:evidence_summary].length).to be <= 1000
        bq_mocks[:response]
      end

      described_class.new.log_findings(scan)
    end
  end

  describe '#log_findings with auto-create' do
    it 'creates dataset and table if they do not exist' do
      create(:finding, scan:, fingerprint: SecureRandom.hex(32))
      mocks = bq_mocks

      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(nil)
      allow(mock_bigquery).to receive(:create_dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_findings_dev').and_return(nil)
      allow(mocks[:dataset]).to receive(:create_table).with('scan_findings_dev')
                                                      .and_yield(mocks[:table]).and_return(mocks[:table])
      allow(mocks[:table]).to receive(:schema)
      allow(mocks[:table]).to receive(:insert).and_return(mocks[:response])

      expect(mock_bigquery).to receive(:create_dataset).with('pentest_history')
      expect(mocks[:dataset]).to receive(:create_table).with('scan_findings_dev')

      described_class.new.log_findings(scan)
    end
  end

  describe '#log_findings when BigQuery unavailable' do
    it 'logs error and returns zero without raising' do
      create(:finding, scan:, fingerprint: SecureRandom.hex(32))
      allow(mock_bigquery).to receive(:dataset).and_raise(StandardError, 'connection refused')

      expect(Rails.logger).to receive(:error).with(/BigQueryLogger.*connection refused/)
      expect(described_class.new.log_findings(scan)).to eq(0)
    end
  end

  describe '.enabled?' do
    it 'returns true when GOOGLE_CLOUD_PROJECT is set' do
      expect(described_class.enabled?).to be true
    end

    it 'returns false when GOOGLE_CLOUD_PROJECT is not set' do
      stub_const('ENV', ENV.to_h.except('GOOGLE_CLOUD_PROJECT'))
      expect(described_class.enabled?).to be false
    end
  end
end
