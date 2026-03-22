# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe ScanResultsExporter do
  subject(:exporter) { described_class.new(scan) }

  let(:target) { create(:target, name: 'Acme Corp', urls: '["https://acme.com"]') }
  let(:scan) do
    create(:scan, :completed, target:,
                              tool_statuses: { 'zap' => { 'status' => 'completed' }, 'nuclei' => { 'status' => 'completed' } },
                              summary: {
                                'total_findings' => 2,
                                'by_severity' => { 'high' => 1, 'medium' => 1 },
                                'tools_run' => %w[zap nuclei],
                                'duration_seconds' => 300,
                                'executive_summary' => 'Two vulnerabilities identified.'
                              })
  end

  let!(:high_finding) do
    create(:finding,
           scan:,
           source_tool: 'zap',
           severity: 'high',
           title: 'SQL Injection',
           url: 'https://acme.com/login',
           parameter: 'username',
           cwe_id: 'CWE-89',
           cve_id: 'CVE-2024-1234',
           cvss_score: 9.8,
           epss_score: 0.95,
           kev_known_exploited: true,
           evidence: { 'description' => 'Injection in login form' },
           ai_assessment: { 'summary' => 'Critical risk', 'recommendation' => 'Use parameterized queries' },
           duplicate: false)
  end

  let!(:medium_finding) do
    create(:finding,
           scan:,
           source_tool: 'nuclei',
           severity: 'medium',
           title: 'Missing Security Headers',
           url: 'https://acme.com/',
           cwe_id: 'CWE-693',
           duplicate: false)
  end

  let!(:duplicate_finding) do
    create(:finding,
           scan:,
           source_tool: 'nikto',
           severity: 'medium',
           title: 'Duplicate Finding',
           url: 'https://acme.com/',
           duplicate: true)
  end

  let(:storage_service) { instance_double(StorageService) }

  before do
    allow(StorageService).to receive(:new).and_return(storage_service)
    allow(storage_service).to receive(:upload).and_return(true)
  end

  describe '#build_envelope' do
    let(:envelope) { exporter.build_envelope }

    it 'includes schema_version' do
      expect(envelope[:schema_version]).to eq('1.0')
    end

    describe 'metadata' do
      let(:metadata) { envelope[:metadata] }

      it 'includes scan identification' do
        expect(metadata[:scan_id]).to eq(scan.id)
        expect(metadata[:target_name]).to eq('Acme Corp')
        expect(metadata[:target_urls]).to eq(['https://acme.com'])
        expect(metadata[:profile]).to eq('standard')
      end

      it 'includes timing data' do
        expect(metadata[:started_at]).to be_present
        expect(metadata[:completed_at]).to be_present
        expect(metadata[:duration_seconds]).to be_a(Integer)
        expect(metadata[:generated_at]).to be_present
      end

      it 'includes tool statuses' do
        expect(metadata[:tool_statuses]).to eq(
          'zap' => { 'status' => 'completed' },
          'nuclei' => { 'status' => 'completed' }
        )
      end
    end

    describe 'summary' do
      let(:summary) { envelope[:summary] }

      it 'includes finding counts' do
        expect(summary[:total_findings]).to eq(2)
        expect(summary[:by_severity]).to eq('high' => 1, 'medium' => 1)
      end

      it 'includes tools and duration' do
        expect(summary[:tools_run]).to eq(%w[zap nuclei])
        expect(summary[:duration_seconds]).to eq(300)
      end

      it 'includes executive summary' do
        expect(summary[:executive_summary]).to eq('Two vulnerabilities identified.')
      end
    end

    describe 'findings' do
      it 'excludes duplicate findings' do
        titles = envelope[:findings].pluck(:title)
        expect(titles).to include('SQL Injection', 'Missing Security Headers')
        expect(titles).not_to include('Duplicate Finding')
      end

      it 'includes all enrichment fields' do
        sql_finding = envelope[:findings].find { |f| f[:title] == 'SQL Injection' }

        expect(sql_finding[:source_tool]).to eq('zap')
        expect(sql_finding[:severity]).to eq('high')
        expect(sql_finding[:parameter]).to eq('username')
        expect(sql_finding[:cwe_id]).to eq('CWE-89')
        expect(sql_finding[:cve_id]).to eq('CVE-2024-1234')
        expect(sql_finding[:cvss_score]).to eq(9.8)
        expect(sql_finding[:epss_score]).to eq(0.95)
        expect(sql_finding[:kev_known_exploited]).to be(true)
      end

      it 'includes evidence and AI assessment' do
        sql_finding = envelope[:findings].find { |f| f[:title] == 'SQL Injection' }

        expect(sql_finding[:evidence]).to eq('description' => 'Injection in login form')
        expect(sql_finding[:ai_assessment]).to include('summary' => 'Critical risk')
      end
    end
  end

  describe '#export' do
    it 'returns the GCS path' do
      gcs_path = exporter.export

      expect(gcs_path).to eq("scan-results/#{target.id}/#{scan.id}/scan_results.json")
    end

    it 'uploads JSON to storage' do
      exporter.export

      expect(storage_service).to have_received(:upload).with(
        anything,
        "scan-results/#{target.id}/#{scan.id}/scan_results.json",
        content_type: 'application/json'
      )
    end

    it 'produces valid JSON' do
      allow(storage_service).to receive(:upload) do |local_path, _remote, **_opts|
        content = File.read(local_path)
        parsed = JSON.parse(content)
        expect(parsed['schema_version']).to eq('1.0')
        expect(parsed['findings'].size).to eq(2)
        true
      end

      exporter.export
    end

    it 'cleans up temp files' do
      exporter.export

      tmp_dir = Penetrator.root.join('tmp', 'scan_results', scan.id)
      expect(File.directory?(tmp_dir)).to be(false)
    end
  end

  describe 'SCHEMA_VERSION' do
    it 'is a semantic version string' do
      expect(described_class::SCHEMA_VERSION).to match(/\A\d+\.\d+\z/)
    end
  end

  describe 'with missing summary' do
    let(:scan) do
      create(:scan, :completed, target:, summary: nil, tool_statuses: {})
    end

    it 'falls back to computed values' do
      envelope = exporter.build_envelope

      expect(envelope[:summary][:total_findings]).to eq(2)
      expect(envelope[:summary][:executive_summary]).to be_nil
    end
  end
end
