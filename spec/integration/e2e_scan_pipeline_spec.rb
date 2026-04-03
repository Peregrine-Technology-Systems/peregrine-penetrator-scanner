require 'sequel_helper'

RSpec.describe 'E2E Scan Pipeline', :integration do # rubocop:disable RSpec/DescribeClass
  let(:target) { create(:target, name: 'DVWA E2E Test', urls: ['http://dvwa:80']) }
  let(:scan) { create(:scan, target:, profile: 'quick') }

  let(:mock_findings) do
    [
      { source_tool: 'zap', severity: 'high', title: 'SQL Injection', url: 'http://dvwa:80/login.php',
        parameter: 'username', cwe_id: 'CWE-89', evidence: { description: 'Login form injectable' } },
      { source_tool: 'zap', severity: 'medium', title: 'Missing X-Frame-Options', url: 'http://dvwa:80/',
        cwe_id: 'CWE-1021', evidence: { description: 'Clickjacking possible' } },
      { source_tool: 'nuclei', severity: 'high', title: 'CVE-2021-44228 Log4Shell', url: 'http://dvwa:80/',
        cve_id: 'CVE-2021-44228', cwe_id: 'CWE-917', evidence: { description: 'JNDI injection' } },
      { source_tool: 'zap', severity: 'high', title: 'SQL Injection', url: 'http://dvwa:80/login.php',
        parameter: 'username', cwe_id: 'CWE-89', evidence: { description: 'Duplicate — same fingerprint' } }
    ]
  end

  before do
    # Mock all scanners to return findings without running real tools
    mock_profile = ScanProfile.load('quick')
    allow(ScanProfile).to receive(:load).and_return(mock_profile)

    mock_scanner = instance_double(Scanners::ZapScanner)
    allow(Scanners::ZapScanner).to receive(:new).and_return(mock_scanner)
    allow(mock_scanner).to receive(:run).and_return({ success: true, findings: mock_findings[0..1] })

    mock_nuclei = instance_double(Scanners::NucleiScanner)
    allow(Scanners::NucleiScanner).to receive(:new).and_return(mock_nuclei)
    allow(mock_nuclei).to receive(:run).and_return({ success: true, findings: mock_findings[2..3] })

    # Mock storage (no GCS in tests)
    allow_any_instance_of(StorageService).to receive(:upload) # rubocop:disable RSpec/AnyInstance

    # Stub preflight reachability check
    stub_request(:head, 'http://dvwa/').to_return(status: 200)

    # Stub CVE enrichment APIs (no external calls in tests)
    stub_request(:get, /services.nvd.nist.gov/).to_return(status: 200, body: '{"vulnerabilities":[]}',
                                                          headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, /api.first.org/).to_return(status: 200, body: '{"data":[]}',
                                                  headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, /www.cisa.gov/).to_return(status: 200, body: '{"vulnerabilities":[]}',
                                                 headers: { 'Content-Type' => 'application/json' })
  end

  describe 'full pipeline: scan → normalize → export' do
    it 'orchestrates a scan and produces findings' do
      orchestrator = ScanOrchestrator.new(scan)
      orchestrator.execute

      scan.refresh
      expect(scan.status).to eq('completed')
      expect(scan.findings_dataset.count).to be >= 2
    end

    it 'normalizes and deduplicates findings' do
      orchestrator = ScanOrchestrator.new(scan)
      orchestrator.execute

      non_dup = scan.findings_dataset.non_duplicate
      duplicates = scan.findings_dataset.where(duplicate: true)

      # 4 findings created, at least 1 should be marked duplicate (same fingerprint)
      expect(non_dup.count + duplicates.count).to eq(scan.findings_dataset.count)
    end

    it 'builds a summary with severity counts' do
      orchestrator = ScanOrchestrator.new(scan)
      orchestrator.execute

      scan.refresh
      summary = scan.summary
      expect(summary).to include('total_findings')
      expect(summary['by_severity']).to be_a(Hash)
    end

    it 'exports a v1.1 JSON envelope' do
      orchestrator = ScanOrchestrator.new(scan)
      orchestrator.execute

      exporter = ScanResultsExporter.new(scan)
      envelope = exporter.build_envelope

      expect(envelope[:schema_version]).to eq('1.1')
      expect(envelope[:metadata][:scan_id]).to eq(scan.id)
      expect(envelope[:metadata][:target_name]).to eq('DVWA E2E Test')
      expect(envelope[:findings]).to be_an(Array)
      expect(envelope[:findings].length).to be >= 1
    end

    it 'includes expected finding fields in JSON export' do
      orchestrator = ScanOrchestrator.new(scan)
      orchestrator.execute

      exporter = ScanResultsExporter.new(scan)
      finding = exporter.build_envelope[:findings].first

      expect(finding).to include(:id, :source_tool, :severity, :title, :url)
    end
  end
end
