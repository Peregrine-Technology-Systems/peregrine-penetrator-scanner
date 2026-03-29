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
    describe 'NucleiParser' do
      subject(:results) { ResultParsers::NucleiParser.new(fixtures.join('nuclei_results.jsonl').to_s).parse }

      it 'parses all JSONL lines from fixture' do
        expect(results.length).to eq(3)
      end

      it 'extracts CVE, CWE, CVSS, and EPSS from classification' do
        log4j = results.find { |f| f[:title] =~ /Log4j/ }

        expect(log4j[:cve_id]).to eq('CVE-2021-44228')
        expect(log4j[:cwe_id]).to eq('CWE-502')
        expect(log4j[:cvss_score]).to eq(10.0)
        expect(log4j[:cvss_vector]).to start_with('CVSS:3.1/')
        expect(log4j[:epss_score]).to be_a(Float)
      end

      it 'returns nil enrichment fields when classification lacks them' do
        tech = results.find { |f| f[:title] == 'Technology Detection' }

        expect(tech[:cve_id]).to be_nil
        expect(tech[:cvss_score]).to be_nil
        expect(tech[:cvss_vector]).to be_nil
        expect(tech[:epss_score]).to be_nil
      end

      it 'produces findings that persist to the database' do
        scan = create(:scan, :running)
        log4j = results.find { |f| f[:title] =~ /Log4j/ }

        finding = Finding.create(log4j.merge(scan_id: scan.id))
        finding.reload

        expect(finding.source_tool).to eq('nuclei')
        expect(finding.cvss_score).to eq(10.0)
        expect(finding.cvss_vector).to start_with('CVSS:3.1/')
        expect(finding.epss_score).to be_a(Float)
      end
    end

    describe 'ZapParser' do
      subject(:results) { ResultParsers::ZapParser.new(fixtures.join('zap_results.json').to_s).parse }

      it 'parses all instances from fixture' do
        expect(results.length).to eq(3)
      end

      it 'extracts CWE ID with prefix' do
        xss = results.find { |f| f[:title] =~ /Cross Site Scripting/ }
        expect(xss[:cwe_id]).to eq('CWE-79')
      end

      it 'maps risk codes to severity levels' do
        severities = results.map { |f| f[:severity] }
        expect(severities).to include('low', 'high')
      end

      it 'extracts parameters from instances' do
        xss = results.find { |f| f[:parameter] == 'q' }
        expect(xss).not_to be_nil
      end

      it 'produces findings that persist to the database' do
        scan = create(:scan, :running)
        xss = results.find { |f| f[:title] =~ /Cross Site Scripting/ }

        finding = Finding.create(xss.merge(scan_id: scan.id))
        expect(finding.id).to be_present
        expect(finding.fingerprint).to be_present
      end
    end

    describe 'NiktoParser' do
      subject(:results) { ResultParsers::NiktoParser.new(fixtures.join('nikto_results.json').to_s).parse }

      it 'parses vulnerabilities from fixture' do
        expect(results.length).to eq(2)
      end

      it 'sets source_tool to nikto' do
        expect(results.all? { |f| f[:source_tool] == 'nikto' }).to be true
      end

      it 'includes evidence with OSVDB reference' do
        git_finding = results.find { |f| f[:url]&.include?('.git') }
        expect(git_finding[:evidence]).to include(:id)
      end

      it 'produces findings that persist to the database' do
        scan = create(:scan, :running)
        finding = Finding.create(results.first.merge(scan_id: scan.id))
        expect(finding.id).to be_present
      end
    end

    describe 'FfufParser' do
      subject(:results) { ResultParsers::FfufParser.new(fixtures.join('ffuf_results.json').to_s).parse }

      it 'parses all results from fixture' do
        expect(results.length).to eq(3)
      end

      it 'maps status codes to severity' do
        admin = results.find { |f| f[:title] =~ /admin/ }
        backup = results.find { |f| f[:title] =~ /backup/ }

        expect(admin[:severity]).to eq('info')
        expect(backup[:severity]).to eq('low')
      end

      it 'extracts discovered URLs' do
        urls = results.map { |f| f[:url] }
        expect(urls).to include('https://example.com/admin')
      end

      it 'produces findings that persist to the database' do
        scan = create(:scan, :running)
        finding = Finding.create(results.first.merge(scan_id: scan.id))
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

  describe 'FindingNormalizer' do
    it 'deduplicates findings with identical title/url/param/cwe' do
      scan = create(:scan, :running)
      Finding.create(scan_id: scan.id, source_tool: 'zap', severity: 'high',
                     title: 'XSS', url: 'https://example.com/search', parameter: 'q', cwe_id: 'CWE-79')
      Finding.create(scan_id: scan.id, source_tool: 'nuclei', severity: 'high',
                     title: 'XSS', url: 'https://example.com/search', parameter: 'q', cwe_id: 'CWE-79')
      Finding.create(scan_id: scan.id, source_tool: 'zap', severity: 'medium',
                     title: 'Missing Header', url: 'https://example.com/', cwe_id: 'CWE-693')

      FindingNormalizer.new(scan).normalize

      expect(scan.findings_dataset.where(duplicate: true).count).to eq(1)
      expect(scan.findings_dataset.non_duplicate.count).to eq(2)
    end
  end

  describe 'SeverityCvssMapper' do
    it 'maps all severity levels to CVSS scores' do
      scan = create(:scan, :running)
      %w[critical high medium low info].each do |sev|
        Finding.create(scan_id: scan.id, source_tool: 'zap', severity: sev,
                       title: "#{sev} finding", url: "https://example.com/#{sev}")
      end

      scan.findings_dataset.each { |f| SeverityCvssMapper.enrich(f) }

      scores = scan.findings_dataset.order(:severity).all.to_h { |f| [f.severity, f.cvss_score] }
      expect(scores['critical']).to eq(9.5)
      expect(scores['high']).to eq(7.5)
      expect(scores['medium']).to eq(5.0)
      expect(scores['low']).to eq(2.5)
      expect(scores['info']).to eq(0.0)
    end
  end

  describe 'CveIntelligenceService enrichment pipeline' do
    before do
      stub_request(:get, /services.nvd.nist.gov/).to_return(
        status: 200,
        body: {
          'vulnerabilities' => [{
            'cve' => {
              'id' => 'CVE-2021-44228',
              'descriptions' => [{ 'lang' => 'en', 'value' => 'Log4j RCE' }],
              'metrics' => {
                'cvssMetricV31' => [{
                  'cvssData' => { 'baseScore' => 10.0, 'vectorString' => 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H' }
                }]
              },
              'references' => [],
              'configurations' => []
            }
          }]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      stub_request(:get, /api.first.org/).to_return(
        status: 200,
        body: { 'data' => [{ 'cve' => 'CVE-2021-44228', 'epss' => '0.975' }] }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      stub_request(:get, /www.cisa.gov/).to_return(
        status: 200,
        body: { 'vulnerabilities' => [{ 'cveID' => 'CVE-2021-44228' }] }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    end

    it 'enriches a finding with CVSS, EPSS, KEV, and vector from APIs' do
      scan = create(:scan, :running)
      finding = Finding.create(
        scan_id: scan.id, source_tool: 'nuclei', severity: 'critical',
        title: 'Log4Shell', cve_id: 'CVE-2021-44228',
        evidence: { 'description' => 'test' }
      )

      CveIntelligenceService.new.enrich_finding(finding)
      finding.reload

      expect(finding.cvss_score).to eq(10.0)
      expect(finding.cvss_vector).to eq('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H')
      expect(finding.epss_score).to eq(0.975)
      expect(finding.kev_known_exploited).to be true
    end

    it 'skips API calls when Nuclei template data is present' do
      scan = create(:scan, :running)
      finding = Finding.create(
        scan_id: scan.id, source_tool: 'nuclei', severity: 'critical',
        title: 'Log4Shell', cve_id: 'CVE-2021-44228',
        cvss_score: 10.0, cvss_vector: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H',
        epss_score: 0.97565, evidence: {}
      )

      CveIntelligenceService.new.enrich_finding(finding)

      expect(WebMock).not_to have_requested(:get, /services.nvd.nist.gov/)
      expect(WebMock).not_to have_requested(:get, /api.first.org/)
    end

    it 'enriches CVE findings via APIs' do
      scan = create(:scan, :running)
      nuclei_f = Finding.create(scan_id: scan.id, source_tool: 'nuclei', severity: 'critical',
                                title: 'Log4Shell', cve_id: 'CVE-2021-44228', evidence: {})
      service = CveIntelligenceService.new
      allow(service).to receive(:sleep)
      service.enrich_scan(scan)

      nuclei_f.reload
      expect(nuclei_f.cvss_score).to eq(10.0)
    end

    it 'enriches non-CVE findings via severity mapping' do
      scan = create(:scan, :running)
      zap_f = Finding.create(scan_id: scan.id, source_tool: 'zap', severity: 'high',
                             title: 'XSS', url: 'https://example.com', cwe_id: 'CWE-79')
      service = CveIntelligenceService.new
      allow(service).to receive(:sleep)
      service.enrich_scan(scan)

      zap_f.reload
      expect(zap_f.cvss_score).to eq(7.5)
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

    it 'uses schema version 1.1' do
      envelope = ScanResultsExporter.new(export_scan).build_envelope
      expect(envelope[:schema_version]).to eq('1.1')
    end

    it 'includes CVSS/EPSS/KEV enrichment fields in findings' do
      finding = ScanResultsExporter.new(export_scan).build_envelope[:findings].first

      expect(finding).to include(:cvss_score, :cvss_vector, :epss_score, :kev_known_exploited)
      expect(finding[:cvss_vector]).to start_with('CVSS:3.1/')
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
