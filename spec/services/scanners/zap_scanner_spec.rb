require 'sequel_helper'

RSpec.describe Scanners::ZapScanner do
  let(:target) { create(:target, urls: ['https://example.com'].to_json) }
  let(:scan) { create(:scan, :running, target:) }
  let(:tool_config) { { mode: 'baseline', timeout: 300 } }
  let(:scanner) { described_class.new(scan, tool_config) }

  let(:base) { "http://#{described_class::DAEMON_HOST}:#{described_class::DAEMON_PORT}" }
  let(:empty_report) { { 'site' => [] }.to_json }

  def json(body)
    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  # Stub the full happy-path ZAP API surface. Individual examples override pieces.
  def stub_zap_api(report: empty_report)
    stub_request(:get, "#{base}/JSON/core/view/version/").to_return(json('version' => '2.15'))
    stub_request(:get, %r{#{base}/JSON/core/action/accessUrl/}).to_return(json('Result' => 'OK'))
    stub_request(:get, %r{#{base}/JSON/spider/action/scan/}).to_return(json('scan' => '1'))
    stub_request(:get, %r{#{base}/JSON/spider/view/status/}).to_return(json('status' => '100'))
    stub_request(:get, %r{#{base}/JSON/pscan/view/recordsToScan/}).to_return(json('recordsToScan' => '0'))
    stub_request(:get, %r{#{base}/JSON/ascan/action/scan/}).to_return(json('scan' => '2'))
    stub_request(:get, %r{#{base}/JSON/ascan/view/status/}).to_return(json('status' => '100'))
    stub_request(:get, "#{base}/OTHER/core/other/jsonreport/")
      .to_return(status: 200, body: report, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, "#{base}/JSON/core/action/shutdown/").to_return(json('Result' => 'OK'))
  end

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    allow(Process).to receive(:kill)
    allow(scanner).to receive(:sleep)
    stub_zap_api
  end

  describe '#tool_name' do
    it 'returns zap' do
      expect(scanner.tool_name).to eq('zap')
    end
  end

  describe '#run (native daemon + API)' do
    it 'spawns the zap.sh daemon (not zap-baseline.py)' do
      scanner.run
      expect(Process).to have_received(:spawn).with('zap.sh', '-daemon', any_args)
    end

    it 'runs spider + passive scan and does NOT active-scan in baseline mode' do
      scanner.run
      expect(WebMock).to have_requested(:get, %r{/JSON/spider/action/scan/})
      expect(WebMock).to have_requested(:get, %r{/JSON/pscan/view/recordsToScan/})
      expect(WebMock).not_to have_requested(:get, %r{/JSON/ascan/action/scan/})
    end

    it 'reports success and marks the tool completed' do
      result = scanner.run
      expect(result[:success]).to be(true)
      expect(scan.reload.tool_statuses['zap']['status']).to eq('completed')
    end

    it 'always shuts the daemon down (API shutdown + process kill)' do
      scanner.run
      expect(WebMock).to have_requested(:get, %r{/JSON/core/action/shutdown/})
      expect(Process).to have_received(:kill).with('-TERM', 12_345)
    end

    context 'with full mode' do
      let(:tool_config) { { mode: 'full', timeout: 300 } }

      it 'also runs an active scan' do
        scanner.run
        expect(WebMock).to have_requested(:get, %r{/JSON/ascan/action/scan/})
        expect(WebMock).to have_requested(:get, %r{/JSON/ascan/view/status/})
      end
    end

    context 'with unknown mode' do
      let(:tool_config) { { mode: 'invalid', timeout: 300 } }

      it 'fails with a clear error and never spawns a daemon' do
        result = scanner.run
        expect(result[:success]).to be(false)
        expect(result[:error]).to include('Unknown ZAP mode')
        expect(Process).not_to have_received(:spawn)
      end
    end

    context 'when the daemon never becomes ready' do
      before do
        allow(scanner).to receive(:daemon_ready?).and_return(false)
        allow(scanner).to receive(:monotonic).and_return(0, 1_000)
      end

      it 'fails and still cleans up the spawned process' do
        result = scanner.run
        expect(result[:success]).to be(false)
        expect(result[:error]).to include('did not become ready')
        expect(Process).to have_received(:kill).with('-TERM', 12_345)
      end
    end

    context 'when a poll has not finished yet' do
      before do
        stub_request(:get, %r{#{base}/JSON/spider/view/status/})
          .to_return(json('status' => '40'), json('status' => '100'))
      end

      it 'sleeps and re-polls until complete' do
        scanner.run
        expect(scanner).to have_received(:sleep).at_least(:once)
      end
    end

    context 'when the API returns an error status' do
      before do
        stub_request(:get, %r{#{base}/JSON/spider/action/scan/}).to_return(status: 500, body: 'err')
      end

      it 'fails with the HTTP status' do
        result = scanner.run
        expect(result[:success]).to be(false)
        expect(result[:error]).to include('HTTP 500')
      end
    end

    context 'with a scan timeout' do
      let(:tool_config) { { mode: 'baseline', timeout: 1 } }

      before { allow(scanner).to receive(:scan_origin).and_raise(Timeout::Error) }

      it 'converts the timeout into a clean ZAP error' do
        result = scanner.run
        expect(result[:success]).to be(false)
        expect(result[:error]).to include('timed out')
      end
    end

    it 'parses the ZAP JSON report into findings' do
      report = {
        'site' => [{
          'alerts' => [{
            'name' => 'Reflected XSS', 'riskcode' => '3', 'cweid' => '79',
            'desc' => 'XSS', 'solution' => 'encode', 'reference' => 'owasp',
            'instances' => [{ 'uri' => 'https://example.com/?q=1', 'param' => 'q',
                              'evidence' => '<script>', 'method' => 'GET' }]
          }]
        }]
      }.to_json
      stub_zap_api(report: report)

      result = scanner.run
      expect(result[:success]).to be(true)
      expect(result[:findings].first).to include(source_tool: 'zap', severity: 'high', title: 'Reflected XSS')
    end

    context 'with multiple origins' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://test.com'].to_json) }

      it 'spiders each unique origin once' do
        scanner.run
        expect(WebMock).to have_requested(:get, %r{/JSON/spider/action/scan/}).twice
      end
    end

    context 'with multiple paths on one origin' do
      let(:target) { create(:target, urls: ['https://example.com', 'https://example.com/admin'].to_json) }

      it 'deduplicates to one spider per origin' do
        scanner.run
        expect(WebMock).to have_requested(:get, %r{/JSON/spider/action/scan/}).once
      end
    end
  end
end
