require 'sequel_helper'

RSpec.describe ScanOrchestrator do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, target:, profile: 'standard') }
  let(:orchestrator) { described_class.new(scan) }

  let(:mock_phase) do
    phase = instance_double(ScanProfile::Phase, name: 'discovery', parallel: false)
    tool_config = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
    allow(phase).to receive(:tools).and_return([tool_config])
    phase
  end

  before do
    mock_profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [mock_phase])
    allow(ScanProfile).to receive(:load).and_return(mock_profile)
    allow(FindingNormalizer).to receive(:new).and_return(instance_double(FindingNormalizer, normalize: nil))
    stub_request(:head, 'https://example.com/').to_return(status: 200)
  end

  describe '#execute' do
    let(:mock_scanner) { instance_double(Scanners::ZapScanner) }

    before do
      allow(Scanners::ZapScanner).to receive(:new).and_return(mock_scanner)
      allow(mock_scanner).to receive(:run).and_return({ success: true, findings: [] })
    end

    it 'updates scan status to running' do
      orchestrator.execute
      scan.refresh
      expect(scan.started_at).to be_present
    end

    it 'updates scan status to completed when done' do
      orchestrator.execute
      scan.refresh
      expect(scan.status).to eq('completed')
      expect(scan.completed_at).to be_present
    end

    it 'runs phases in order' do
      order = []
      setup_ordered_phases(order)

      orchestrator.execute
      expect(order).to eq(%i[ffuf zap])
    end

    it 'runs tools in parallel when phase is parallel' do
      parallel_phase = instance_double(ScanProfile::Phase, name: 'discovery', parallel: true)
      tool1 = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
      tool2 = instance_double(ScanProfile::ToolConfig, tool: 'nikto', config: {})
      allow(parallel_phase).to receive(:tools).and_return([tool1, tool2])

      profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [parallel_phase])
      allow(ScanProfile).to receive(:load).and_return(profile)

      ffuf_scanner = instance_double(Scanners::FfufScanner)
      nikto_scanner = instance_double(Scanners::NiktoScanner)
      allow(Scanners::FfufScanner).to receive(:new).and_return(ffuf_scanner)
      allow(Scanners::NiktoScanner).to receive(:new).and_return(nikto_scanner)
      allow(ffuf_scanner).to receive(:run).and_return({ success: true, findings: [] })
      allow(nikto_scanner).to receive(:run).and_return({ success: true, findings: [] })

      orchestrator.execute

      expect(ffuf_scanner).to have_received(:run)
      expect(nikto_scanner).to have_received(:run)
    end

    it 'calls normalize_findings' do
      normalizer = instance_double(FindingNormalizer)
      allow(FindingNormalizer).to receive(:new).with(scan).and_return(normalizer)
      expect(normalizer).to receive(:normalize)

      orchestrator.execute
    end

    it 'generates summary with finding counts' do
      create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'XSS', duplicate: false)
      create(:finding, scan:, severity: 'medium', source_tool: 'zap', title: 'Missing Header', duplicate: false)

      orchestrator.execute

      scan.refresh
      summary = scan.summary
      expect(summary['total_findings']).to eq(2)
      expect(summary['by_severity']).to include('high' => 1, 'medium' => 1)
    end

    it 'saves findings from scanner results' do
      finding_attrs = {
        source_tool: 'zap',
        severity: 'high',
        title: 'XSS Found',
        url: 'https://example.com/page',
        cwe_id: 'CWE-79',
        evidence: { description: 'test' }
      }
      allow(mock_scanner).to receive(:run).and_return({ success: true, findings: [finding_attrs] })

      expect { orchestrator.execute }.to change { scan.findings_dataset.count }.by(1)
    end

    it 'continues when a tool fails (fail-forward)' do
      failing_tool = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
      working_tool = instance_double(ScanProfile::ToolConfig, tool: 'nuclei', config: {})
      phase = instance_double(ScanProfile::Phase, name: 'test', parallel: false)
      allow(phase).to receive(:tools).and_return([failing_tool, working_tool])

      profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase])
      allow(ScanProfile).to receive(:load).and_return(profile)

      failing_scanner = instance_double(Scanners::ZapScanner)
      working_scanner = instance_double(Scanners::NucleiScanner)
      allow(Scanners::ZapScanner).to receive(:new).and_return(failing_scanner)
      allow(Scanners::NucleiScanner).to receive(:new).and_return(working_scanner)
      allow(failing_scanner).to receive(:run).and_raise(StandardError, 'ZAP crashed')
      allow(working_scanner).to receive(:run).and_return({ success: true, findings: [] })

      orchestrator.execute
      expect(working_scanner).to have_received(:run)
    end

    it 'feeds discovered URLs from ffuf to subsequent tools' do
      setup_discovery_and_active_phases
      orchestrator.execute

      target.refresh
      expect(target.url_list).to include('https://example.com/admin')
    end

    it 'skips unknown tools' do
      unknown_tool = instance_double(ScanProfile::ToolConfig, tool: 'unknown_tool', config: {})
      phase = instance_double(ScanProfile::Phase, name: 'test', parallel: false)
      allow(phase).to receive(:tools).and_return([unknown_tool])

      profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase])
      allow(ScanProfile).to receive(:load).and_return(profile)

      expect { orchestrator.execute }.not_to raise_error
    end

    it 'calls CveIntelligenceService.enrich_scan after normalization' do
      enrichment_service = instance_double(CveIntelligenceService)
      allow(CveIntelligenceService).to receive(:new).and_return(enrichment_service)
      expect(enrichment_service).to receive(:enrich_scan).with(scan)

      orchestrator.execute
    end

    it 'completes scan even when enrichment fails' do
      allow(CveIntelligenceService).to receive(:new).and_raise(StandardError, 'API down')

      orchestrator.execute
      scan.refresh
      expect(scan.status).to eq('completed')
    end

    it 'runs preflight reachability check before scan phases' do
      stub_request(:head, 'https://example.com/').to_return(status: 200)

      orchestrator.execute
      scan.refresh
      expect(scan.status).to eq('completed')
      expect(WebMock).to have_requested(:head, 'https://example.com/')
    end

    it 'fails scan immediately when target is unreachable' do
      stub_request(:head, 'https://example.com/').to_raise(Errno::ECONNREFUSED.new('Connection refused'))

      expect { orchestrator.execute }.to raise_error(/Target unreachable/)

      scan.refresh
      expect(scan.status).to eq('failed')
      expect(scan.error_message).to include('Target unreachable')
    end

    it 'skips preflight check for smoke test profiles' do
      smoke_profile = instance_double(ScanProfile, name: 'smoke-test', smoke: false, smoke_test: true, phases: [])
      allow(ScanProfile).to receive(:load).and_return(smoke_profile)
      runner = instance_double(SmokeTestRunner, run: nil)
      allow(SmokeTestRunner).to receive(:new).and_return(runner)

      orchestrator.execute
      expect(WebMock).not_to have_requested(:head, 'https://example.com/')
    end

    it 'marks scan as failed on unrecoverable error' do
      orchestrator_instance = orchestrator
      allow(orchestrator_instance).to receive(:run_phase).and_raise(StandardError, 'Something broke')

      expect { orchestrator_instance.execute }.to raise_error(StandardError)

      scan.refresh
      expect(scan.status).to eq('failed')
      expect(scan.error_message).to include('Something broke')
    end
  end

  private

  def setup_ordered_phases(order)
    phase1 = instance_double(ScanProfile::Phase, name: 'phase1', parallel: false)
    phase2 = instance_double(ScanProfile::Phase, name: 'phase2', parallel: false)
    tool1 = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
    tool2 = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
    allow(phase1).to receive(:tools).and_return([tool1])
    allow(phase2).to receive(:tools).and_return([tool2])

    profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase1, phase2])
    allow(ScanProfile).to receive(:load).and_return(profile)

    ffuf_scanner = instance_double(Scanners::FfufScanner)
    zap_scanner = instance_double(Scanners::ZapScanner)
    allow(Scanners::FfufScanner).to receive(:new).and_return(ffuf_scanner)
    allow(Scanners::ZapScanner).to receive(:new).and_return(zap_scanner)

    allow(ffuf_scanner).to receive(:run) do
      order << :ffuf
      { success: true, findings: [] }
    end
    allow(zap_scanner).to receive(:run) do
      order << :zap
      { success: true, findings: [] }
    end
  end

  def setup_discovery_and_active_phases
    ffuf_phase = instance_double(ScanProfile::Phase, name: 'discovery', parallel: false)
    ffuf_tool = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
    allow(ffuf_phase).to receive(:tools).and_return([ffuf_tool])

    zap_phase = instance_double(ScanProfile::Phase, name: 'active', parallel: false)
    zap_tool = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
    allow(zap_phase).to receive(:tools).and_return([zap_tool])

    profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [ffuf_phase, zap_phase])
    allow(ScanProfile).to receive(:load).and_return(profile)

    ffuf_scanner = instance_double(Scanners::FfufScanner)
    zap_scanner = instance_double(Scanners::ZapScanner)
    allow(Scanners::FfufScanner).to receive(:new).and_return(ffuf_scanner)
    allow(Scanners::ZapScanner).to receive(:new).and_return(zap_scanner)

    allow(ffuf_scanner).to receive(:run).and_return({
                                                      success: true, findings: [],
                                                      discovered_urls: ['https://example.com/admin']
                                                    })
    allow(zap_scanner).to receive(:run).and_return({ success: true, findings: [] })
  end
end
