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
    stub_request(:head, 'https://example.com/').to_return(status: 200)
    stub_default_fingerprinter_registry
  end

  def stub_default_fingerprinter_registry
    registry = instance_double(
      Fingerprinters::FingerprinterRegistry,
      detect: { cms: 'unknown', confidence: 0.0, components: [], detected_at: Time.current.iso8601 }
    )
    allow(Fingerprinters::FingerprinterRegistry).to receive(:new).and_return(registry)
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

    it 'continues when a non-critical tool fails (fail-forward)' do
      scanners = setup_two_phase_with_failing_tool('ZAP crashed')

      orchestrator.execute
      expect(scanners[:working]).to have_received(:run)
    end

    it 'aborts scan when first tool in first phase fails (critical failure)' do
      failing_tool = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
      phase = instance_double(ScanProfile::Phase, name: 'discovery', parallel: false)
      allow(phase).to receive(:tools).and_return([failing_tool])

      profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase])
      allow(ScanProfile).to receive(:load).and_return(profile)

      failing_scanner = instance_double(Scanners::FfufScanner)
      allow(Scanners::FfufScanner).to receive(:new).and_return(failing_scanner)
      allow(failing_scanner).to receive(:run).and_raise(StandardError, 'ffuf connection error')

      expect { orchestrator.execute }.to raise_error(/Critical tool failure/)
      scan.refresh
      expect(scan.status).to eq('failed')
    end

    it 'aborts scan on connection-related errors in any phase' do
      passing_tool = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
      phase1 = instance_double(ScanProfile::Phase, name: 'discovery', parallel: false)
      allow(phase1).to receive(:tools).and_return([passing_tool])

      conn_fail_tool = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
      phase2 = instance_double(ScanProfile::Phase, name: 'active', parallel: false)
      allow(phase2).to receive(:tools).and_return([conn_fail_tool])

      profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase1, phase2])
      allow(ScanProfile).to receive(:load).and_return(profile)

      passing_scanner = instance_double(Scanners::FfufScanner)
      conn_fail_scanner = instance_double(Scanners::ZapScanner)
      allow(Scanners::FfufScanner).to receive(:new).and_return(passing_scanner)
      allow(Scanners::ZapScanner).to receive(:new).and_return(conn_fail_scanner)
      allow(passing_scanner).to receive(:run).and_return({ success: true, findings: [] })
      allow(conn_fail_scanner).to receive(:run).and_raise(StandardError, 'Connection refused - ECONNREFUSED')

      expect { orchestrator.execute }.to raise_error(/Critical tool failure/)
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

    # CVE enrichment moved to scan.rake for proper cost tracking (#651)

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

    context 'when fingerprinting the target' do
      it 'runs fingerprinting and stores cms_inventory on scan.summary' do
        orchestrator.execute

        scan.refresh
        expect(scan.summary['cms_inventory']).to include('cms' => 'unknown', 'confidence' => 0.0)
      end

      it 'preserves cms_inventory in summary after scan completion' do
        orchestrator.execute

        scan.refresh
        expect(scan.summary).to include('cms_inventory', 'total_findings')
      end

      it 'does not abort the scan when fingerprinting raises' do
        registry = instance_double(Fingerprinters::FingerprinterRegistry)
        allow(Fingerprinters::FingerprinterRegistry).to receive(:new).and_return(registry)
        allow(registry).to receive(:detect).and_raise(StandardError, 'detector blew up')

        expect { orchestrator.execute }.not_to raise_error
        scan.refresh
        expect(scan.status).to eq('completed')
      end

      it 'skips fingerprinting on smoke profiles' do
        smoke_profile = instance_double(ScanProfile, name: 'smoke', smoke: true, smoke_test: false, phases: [])
        allow(ScanProfile).to receive(:load).and_return(smoke_profile)
        allow(SmokeChecker).to receive(:new).and_return(instance_double(SmokeChecker, run: {}, passed?: true, results: {}))

        expect(Fingerprinters::FingerprinterRegistry).not_to receive(:new)
        orchestrator.execute
      end
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

  def setup_two_phase_with_failing_tool(error_message)
    passing_tool = instance_double(ScanProfile::ToolConfig, tool: 'ffuf', config: {})
    phase1 = instance_double(ScanProfile::Phase, name: 'discovery', parallel: false)
    allow(phase1).to receive(:tools).and_return([passing_tool])

    failing_tool = instance_double(ScanProfile::ToolConfig, tool: 'zap', config: { mode: 'baseline' })
    working_tool = instance_double(ScanProfile::ToolConfig, tool: 'nuclei', config: {})
    phase2 = instance_double(ScanProfile::Phase, name: 'active', parallel: false)
    allow(phase2).to receive(:tools).and_return([failing_tool, working_tool])

    profile = instance_double(ScanProfile, name: 'standard', smoke: false, smoke_test: false, phases: [phase1, phase2])
    allow(ScanProfile).to receive(:load).and_return(profile)

    passing_scanner = instance_double(Scanners::FfufScanner)
    failing_scanner = instance_double(Scanners::ZapScanner)
    working_scanner = instance_double(Scanners::NucleiScanner)
    allow(Scanners::FfufScanner).to receive(:new).and_return(passing_scanner)
    allow(Scanners::ZapScanner).to receive(:new).and_return(failing_scanner)
    allow(Scanners::NucleiScanner).to receive(:new).and_return(working_scanner)
    allow(passing_scanner).to receive(:run).and_return({ success: true, findings: [] })
    allow(failing_scanner).to receive(:run).and_raise(StandardError, error_message)
    allow(working_scanner).to receive(:run).and_return({ success: true, findings: [] })

    { passing: passing_scanner, failing: failing_scanner, working: working_scanner }
  end

  describe 'bus-envelope identity (scanner#1005)' do
    around do |example|
      saved = ENV.fetch('TRANSACTION_ID', nil)
      example.run
    ensure
      saved.nil? ? ENV.delete('TRANSACTION_ID') : ENV['TRANSACTION_ID'] = saved
    end

    it 'stamps the scan_started marker with bus-envelope identity' do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(InstanceMetadata).to receive(:tp_id).and_return('tp-7')
      ENV['TRANSACTION_ID'] = 'txn-42'

      expect(storage).to receive(:upload_json).with(
        a_string_matching(%r{\Acontrol/.+/scan_started\.json\z}),
        hash_including(transaction_id: 'txn-42', tp_id: 'tp-7')
      )

      orchestrator.send(:write_started_marker)
    end

    it 'passes the same memoised identity to the control plane loop' do
      allow(InstanceMetadata).to receive(:tp_id).and_return('tp-7')
      loop_double = instance_double(ControlPlaneLoop, start: nil)
      expect(ControlPlaneLoop).to receive(:new)
        .with(hash_including(identity: an_instance_of(ScanIdentity)))
        .and_return(loop_double)

      orchestrator.send(:start_control_plane)
    end

    it 'warns but does not raise when the started-marker write fails' do
      allow(InstanceMetadata).to receive(:tp_id).and_return('tp-7')
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload_json).and_raise('gcs down')
      allow(Penetrator.logger).to receive(:warn)

      expect { orchestrator.send(:write_started_marker) }.not_to raise_error
      expect(Penetrator.logger).to have_received(:warn).with(/Started marker write failed/)
    end
  end

  describe 'terminal + cancel paths' do
    it 'marks the scan failed on a hard timeout' do
      allow(orchestrator).to receive(:prepare_scan).and_raise(Timeout::Error)

      orchestrator.execute

      scan.refresh
      expect(scan.status).to eq('failed')
      expect(scan.error_message).to include('timed out')
    end

    it 'mark_cancelled sets cancelled status and a summary' do
      orchestrator.send(:mark_cancelled)

      scan.refresh
      expect(scan.status).to eq('cancelled')
      expect(scan.completed_at).not_to be_nil
    end

    it 'save_findings skips a duplicate finding (Sequel::ValidationFailed)' do
      allow(Finding).to receive(:from_contract).and_raise(Sequel::ValidationFailed.new('dup'))
      allow(Penetrator.logger).to receive(:warn)

      orchestrator.send(:save_findings, [{ 'title' => 'x' }])

      expect(Penetrator.logger).to have_received(:warn).with(/Duplicate finding skipped/)
    end
  end

  describe 'smoke profile' do
    it 'runs smoke checks and logs each result' do
      smoke_profile = instance_double(ScanProfile, name: 'smoke', smoke: true, smoke_test: false, phases: [])
      allow(ScanProfile).to receive(:load).and_return(smoke_profile)
      checker = instance_double(SmokeChecker, run: { 'ok' => 1 }, passed?: true,
                                              results: { 'db' => { status: 'ok', detail: 'reachable' } })
      allow(SmokeChecker).to receive(:new).and_return(checker)
      allow(Penetrator.logger).to receive(:info).and_call_original

      described_class.new(scan).execute

      expect(Penetrator.logger).to have_received(:info).with(/SmokeChecker.*db: ok/)
    end
  end
end
