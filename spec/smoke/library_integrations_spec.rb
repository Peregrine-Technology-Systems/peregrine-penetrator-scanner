# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe 'Library integration smoke tests', :smoke do # rubocop:disable RSpec/DescribeClass
  let(:fixtures) { Penetrator.root.join('spec/fixtures') }

  describe 'Boot verification' do
    it 'connects to database' do
      expect(Penetrator.db).to be_a(Sequel::SQLite::Database)
    end

    it 'runs in test environment' do
      expect(Penetrator.env).to eq('test')
    end

    it 'has a logger' do
      expect(Penetrator.logger).to be_a(Logger)
    end

    it 'has project root set' do
      expect(Penetrator.root.join('Gemfile')).to exist
    end
  end

  describe 'Parser integrations' do
    def ids(finding, type)
      (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
    end

    describe 'NucleiParser' do
      subject(:results) { ResultParsers::NucleiParser.new(fixtures.join('nuclei_results.jsonl').to_s).parse }

      it 'parses all JSONL lines from fixture' do
        expect(results.length).to eq(3)
      end

      it 'extracts CVE, CWE, and tool-reported scores from classification' do
        log4j = results.find { |f| f['title'] =~ /Log4j/ }

        expect(ids(log4j, 'cve')).to include('CVE-2021-44228')
        expect(ids(log4j, 'cwe')).to include('CWE-502')
        expect(log4j['scores']).to include('cvss_score' => 10.0)
        expect(log4j['scores']['cvss_vector']).to start_with('CVSS:3.1/')
        expect(log4j['scores']['epss_score']).to be_a(Float)
      end

      it 'omits scores and identifiers when classification lacks them' do
        tech = results.find { |f| f['title'] == 'Technology Detection' }

        expect(tech['scores']).to be_nil
        expect(ids(tech, 'cve')).to be_empty
      end

      it 'persists to the database via the contract' do
        scan = create(:scan, :running)
        log4j = results.find { |f| f['title'] =~ /Log4j/ }

        finding = Finding.from_contract(log4j, scan_id: scan.id).reload

        expect(finding.source_tool).to eq('nuclei')
        expect(finding.finding_type).to eq('vulnerability')
        expect(finding.data.dig('scores', 'cvss_score')).to eq(10.0)
      end
    end

    describe 'ZapParser' do
      subject(:results) { ResultParsers::ZapParser.new(fixtures.join('zap_results.json').to_s).parse }

      it 'parses all instances from fixture' do
        expect(results.length).to eq(3)
      end

      it 'extracts CWE ID with prefix into identifiers' do
        xss = results.find { |f| f['title'] =~ /Cross Site Scripting/ }
        expect(ids(xss, 'cwe')).to include('CWE-79')
      end

      it 'maps risk codes to severity levels' do
        expect(results.map { |f| f['severity'] }).to include('low', 'high')
      end

      it 'extracts parameters into the web location' do
        expect(results.find { |f| f.dig('location', 'parameter') == 'q' }).not_to be_nil
      end

      it 'persists to the database via the contract' do
        scan = create(:scan, :running)
        xss = results.find { |f| f['title'] =~ /Cross Site Scripting/ }

        finding = Finding.from_contract(xss, scan_id: scan.id)
        expect(finding.id).to be_present
        expect(finding.fingerprint).to be_present
      end
    end

    describe 'NiktoParser' do
      subject(:results) { ResultParsers::NiktoParser.new(fixtures.join('nikto_results.json').to_s).parse }

      it 'parses vulnerabilities from fixture' do
        expect(results.length).to eq(2)
      end

      it 'tags findings as nikto misconfigurations' do
        expect(results).to all(include('source_tool' => 'nikto', 'finding_type' => 'misconfiguration'))
      end

      it 'records a tool_check_id and a web location' do
        expect(results.first['tool_check_id']).to be_present
        expect(results.first.dig('location', 'url')).to be_present
      end

      it 'persists to the database via the contract' do
        scan = create(:scan, :running)
        finding = Finding.from_contract(results.first, scan_id: scan.id)
        expect(finding.id).to be_present
      end
    end

    describe 'FfufParser' do
      subject(:results) { ResultParsers::FfufParser.new(fixtures.join('ffuf_results.json').to_s).parse }

      it 'parses all results from fixture' do
        expect(results.length).to eq(3)
      end

      it 'maps status codes to severity' do
        admin = results.find { |f| f['title'] =~ /admin/ }
        backup = results.find { |f| f['title'] =~ /backup/ }

        expect(admin['severity']).to eq('info')
        expect(backup['severity']).to eq('low')
      end

      it 'extracts discovered URLs into the web location' do
        urls = results.map { |f| f.dig('location', 'url') }
        expect(urls).to include('https://example.com/admin')
      end

      it 'persists to the database via the contract' do
        scan = create(:scan, :running)
        finding = Finding.from_contract(results.first, scan_id: scan.id)
        expect(finding.id).to be_present
      end
    end
  end

  describe 'Model creation without factories' do
    let(:smoke_target) { Target.create(name: 'Smoke Test', urls: ['https://example.com']) }
    let(:smoke_scan) { Scan.create(target_id: smoke_target.id, profile: 'quick') }

    it 'creates a Target with default auth_type' do
      smoke_target.reload
      expect(smoke_target.id).to be_present
      expect(smoke_target.auth_type).to eq('none')
    end

    it 'creates a Scan with default status' do
      smoke_scan.reload
      expect(smoke_scan.id).to be_present
      expect(smoke_scan.status).to eq('pending')
    end

    it 'persists CVSS/EPSS enrichment fields on Finding' do
      finding = Finding.create(
        scan_id: smoke_scan.id, source_tool: 'nuclei', severity: 'critical',
        title: 'Log4Shell', url: 'https://example.com/api', cve_id: 'CVE-2021-44228',
        cwe_id: 'CWE-502', cvss_score: 10.0, epss_score: 0.97565,
        cvss_vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H',
        kev_known_exploited: true, evidence: { 'description' => 'JNDI injection' }
      )
      finding.reload

      expect(finding.cvss_score).to eq(10.0)
      expect(finding.cvss_vector).to start_with('CVSS:3.1/')
      expect(finding.epss_score).to eq(0.97565)
      expect(finding.kev_known_exploited).to be true
    end

    it 'auto-generates fingerprint from finding fields' do
      finding = Finding.create(
        scan_id: smoke_scan.id, source_tool: 'zap', severity: 'high',
        title: 'XSS', url: 'https://example.com/search', parameter: 'q', cwe_id: 'CWE-79'
      )

      expected = Digest::SHA256.hexdigest('zap:XSS:https://example.com/search:q:CWE-79')
      expect(finding.fingerprint).to eq(expected)
    end

    it 'rejects invalid severity' do
      expect do
        Finding.create(scan_id: smoke_scan.id, source_tool: 'zap', severity: 'extreme', title: 'Bad')
      end.to raise_error(Sequel::ValidationFailed)
    end
  end

  describe 'Export pipeline' do
    let(:export_scan) do
      create(:scan, :completed,
             tool_statuses: { 'zap' => { 'status' => 'completed' } },
             summary: { 'total_findings' => 1, 'by_severity' => { 'high' => 1 },
                        'tools_run' => ['zap'], 'duration_seconds' => 60 })
    end

    before do
      create(:finding, scan: export_scan, source_tool: 'zap', severity: 'high', title: 'XSS',
                       url: 'https://example.com', cvss_score: 7.5,
                       cvss_vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N',
                       epss_score: 0.5, kev_known_exploited: false, duplicate: false)
    end

    it 'uses schema version 2.1' do
      envelope = ScanResultsExporter.new(export_scan).build_envelope
      expect(envelope[:schema_version]).to eq('2.1')
    end

    it 'carries tool-reported scores in findings (no analyzer-owned kev)' do
      finding = ScanResultsExporter.new(export_scan).build_envelope[:findings].first

      expect(finding['scores']).to include('cvss_score' => 7.5, 'epss_score' => 0.5)
      expect(finding['scores']['cvss_vector']).to start_with('CVSS:3.1/')
      expect(finding).not_to have_key('kev_known_exploited')
    end
  end

  describe 'ScanSummaryBuilder' do
    it 'counts non-duplicate findings grouped by severity' do
      scan = create(:scan, :running, tool_statuses: { 'zap' => {} })
      create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'A', duplicate: false)
      create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'B', duplicate: false)
      create(:finding, scan:, severity: 'medium', source_tool: 'zap', title: 'C', duplicate: false)
      create(:finding, scan:, severity: 'low', source_tool: 'zap', title: 'D', duplicate: true)

      summary = ScanSummaryBuilder.new(scan).build

      expect(summary[:total_findings]).to eq(3)
      expect(summary[:by_severity]).to eq('high' => 2, 'medium' => 1)
      expect(summary[:tools_run]).to eq(['zap'])
    end
  end
end
