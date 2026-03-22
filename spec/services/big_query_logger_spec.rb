# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BigQueryLogger do
  let(:target) { create(:target, name: 'Test App', urls: ['https://example.com']) }
  let(:scan) { create(:scan, target:, profile: 'quick', status: 'completed') }
  let(:mock_bigquery) { instance_double(Google::Cloud::Bigquery::Project) }

  let(:bq_mocks) do
    dataset = instance_double(Google::Cloud::Bigquery::Dataset)
    findings_table = instance_double(Google::Cloud::Bigquery::Table, table_id: 'scan_findings_dev')
    metadata_table = instance_double(Google::Cloud::Bigquery::Table, table_id: 'scan_metadata_dev')
    response = instance_double(Google::Cloud::Bigquery::InsertResponse, success?: true)
    { dataset:, findings_table:, metadata_table:, response: }
  end

  before do
    allow(Google::Cloud::Bigquery).to receive(:new).and_return(mock_bigquery)
    stub_const('ENV', ENV.to_h.merge(
                        'GOOGLE_CLOUD_PROJECT' => 'peregrine-pentest-dev',
                        'SCAN_MODE' => 'dev'
                      ))
  end

  describe '#initialize' do
    it 'sets table names based on SCAN_MODE' do
      logger = described_class.new
      expect(logger.findings_table_name).to eq('scan_findings_dev')
      expect(logger.metadata_table_name).to eq('scan_metadata_dev')
    end

    it 'keeps legacy table_name alias' do
      expect(described_class.new.table_name).to eq('scan_findings_dev')
    end
  end

  describe '#log_from_json' do
    let(:scan_results) do
      {
        'schema_version' => '1.0',
        'metadata' => {
          'scan_id' => 'test-scan-123',
          'target_name' => 'Test App',
          'target_urls' => ['https://example.com'],
          'profile' => 'quick',
          'started_at' => '2026-03-22T10:00:00Z',
          'completed_at' => '2026-03-22T10:30:00Z',
          'duration_seconds' => 1800,
          'tool_statuses' => { 'zap' => { 'status' => 'completed' } }
        },
        'summary' => {
          'total_findings' => 2,
          'by_severity' => { 'high' => 1, 'medium' => 1 },
          'tools_run' => ['zap'],
          'duration_seconds' => 1800
        },
        'findings' => [
          {
            'id' => 'finding-1',
            'source_tool' => 'zap',
            'severity' => 'high',
            'title' => 'SQL Injection',
            'url' => 'https://example.com/login',
            'parameter' => 'username',
            'cwe_id' => 'CWE-89',
            'cve_id' => 'CVE-2024-1234',
            'cvss_score' => 9.8,
            'epss_score' => 0.95,
            'kev_known_exploited' => true,
            'evidence' => { 'description' => 'Injection found' }
          },
          {
            'id' => 'finding-2',
            'source_tool' => 'nuclei',
            'severity' => 'medium',
            'title' => 'Missing Headers',
            'url' => 'https://example.com/',
            'cwe_id' => 'CWE-693',
            'evidence' => {}
          }
        ]
      }
    end

    before do
      mocks = bq_mocks
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_findings_dev').and_return(mocks[:findings_table])
      allow(mocks[:dataset]).to receive(:table).with('scan_metadata_dev').and_return(mocks[:metadata_table])
      allow(mocks[:findings_table]).to receive(:insert).and_return(mocks[:response])
      allow(mocks[:metadata_table]).to receive(:insert).and_return(mocks[:response])
    end

    it 'inserts findings from JSON envelope' do
      table = bq_mocks[:findings_table]
      allow(table).to receive(:insert) do |rows|
        expect(rows.length).to eq(2)
        row = rows.first
        expect(row[:severity]).to eq('high')
        expect(row[:title]).to eq('SQL Injection')
        expect(row[:schema_version]).to eq('1.0')
        expect(row[:scan_id]).to eq('test-scan-123')
        bq_mocks[:response]
      end

      described_class.new.log_from_json(scan_results)
    end

    it 'includes expanded CVE fields' do
      table = bq_mocks[:findings_table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:cve_id]).to eq('CVE-2024-1234')
        expect(row[:cvss_score]).to eq(9.8)
        expect(row[:epss_score]).to eq(0.95)
        expect(row[:kev_known_exploited]).to be(true)
        expect(row[:parameter]).to eq('username')
        bq_mocks[:response]
      end

      described_class.new.log_from_json(scan_results)
    end

    it 'stores full evidence as JSON string' do
      table = bq_mocks[:findings_table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:evidence]).to eq('{"description":"Injection found"}')
        bq_mocks[:response]
      end

      described_class.new.log_from_json(scan_results)
    end

    it 'inserts scan metadata row' do
      table = bq_mocks[:metadata_table]
      allow(table).to receive(:insert) do |rows|
        expect(rows.length).to eq(1)
        row = rows.first
        expect(row[:scan_id]).to eq('test-scan-123')
        expect(row[:target_name]).to eq('Test App')
        expect(row[:profile]).to eq('quick')
        expect(row[:schema_version]).to eq('1.0')
        expect(row[:total_findings]).to eq(2)
        bq_mocks[:response]
      end

      described_class.new.log_from_json(scan_results)
    end

    it 'returns the count of logged findings' do
      expect(described_class.new.log_from_json(scan_results)).to eq(2)
    end

    it 'returns zero for empty findings' do
      scan_results['findings'] = []
      # Still inserts metadata even with no findings
      mocks = bq_mocks
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_metadata_dev').and_return(mocks[:metadata_table])
      allow(mocks[:metadata_table]).to receive(:insert).and_return(mocks[:response])

      expect(described_class.new.log_from_json(scan_results)).to eq(0)
    end

    it 'handles BQ failure gracefully' do
      allow(mock_bigquery).to receive(:dataset).and_raise(StandardError, 'connection refused')
      expect(Penetrator.logger).to receive(:error).with(/BigQueryLogger.*connection refused/)
      expect(described_class.new.log_from_json(scan_results)).to eq(0)
    end
  end

  describe '#log_findings (legacy AR interface)' do
    let(:finding) do
      create(:finding, scan:, severity: 'high', title: 'XSS in login',
                       source_tool: 'zap', url: 'https://example.com/login',
                       cwe_id: 'CWE-79', cve_id: 'CVE-2024-5678',
                       cvss_score: 7.5, epss_score: 0.8,
                       kev_known_exploited: false, parameter: 'q',
                       fingerprint: SecureRandom.hex(32))
    end

    before do
      finding
      mocks = bq_mocks
      allow(mock_bigquery).to receive(:dataset).with('pentest_history').and_return(mocks[:dataset])
      allow(mocks[:dataset]).to receive(:table).with('scan_findings_dev').and_return(mocks[:findings_table])
      allow(mocks[:findings_table]).to receive(:insert).and_return(mocks[:response])
    end

    it 'inserts finding data with expanded schema' do
      table = bq_mocks[:findings_table]
      allow(table).to receive(:insert) do |rows|
        row = rows.first
        expect(row[:fingerprint]).to eq(finding.fingerprint)
        expect(row[:severity]).to eq('high')
        expect(row[:schema_version]).to eq('1.0')
        expect(row[:cve_id]).to eq('CVE-2024-5678')
        expect(row[:cvss_score]).to eq(7.5)
        expect(row[:parameter]).to eq('q')
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

      table = bq_mocks[:findings_table]
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
