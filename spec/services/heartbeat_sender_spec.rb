require 'sequel_helper'

RSpec.describe HeartbeatSender do
  let(:sender) do
    described_class.new(
      callback_url: 'https://reporter.example.com/callbacks',
      scan_uuid: 'scan-123',
      job_id: 'job-456',
      callback_secret: 'secret-token'
    )
  end

  let(:heartbeat_url) { 'https://reporter.example.com/callbacks/heartbeat' }

  describe '#send_heartbeat' do
    it 'POSTs to the reporter heartbeat endpoint' do
      stub = stub_request(:post, heartbeat_url).to_return(status: 200)

      sender.send_heartbeat(status: 'running', progress_pct: 50, current_tool: 'nuclei', findings_count: 5)

      expect(stub).to have_been_requested
    end

    it 'includes job_id, scan_uuid, and progress in payload' do
      stub = stub_request(:post, heartbeat_url)
             .with do |req|
               body = JSON.parse(req.body)
               body['job_id'] == 'job-456' &&
                 body['scan_uuid'] == 'scan-123' &&
                 body['status'] == 'running' &&
                 body['progress_pct'] == 35 &&
                 body['current_tool'] == 'zap'
             end
             .to_return(status: 200)

      sender.send_heartbeat(status: 'running', progress_pct: 35, current_tool: 'zap', findings_count: 3)

      expect(stub).to have_been_requested
    end

    it 'includes last_tool_started_at timestamp' do
      stub = stub_request(:post, heartbeat_url)
             .with { |req| JSON.parse(req.body).key?('last_tool_started_at') }
             .to_return(status: 200)

      sender.send_heartbeat(status: 'running', current_tool: 'nuclei', last_tool_started_at: Time.current.iso8601)

      expect(stub).to have_been_requested
    end

    it 'sends Authorization header with Bearer token' do
      stub = stub_request(:post, heartbeat_url)
             .with(headers: { 'Authorization' => 'Bearer secret-token' })
             .to_return(status: 200)

      sender.send_heartbeat(status: 'running')

      expect(stub).to have_been_requested
    end

    it 'does not raise on connection failure' do
      stub_request(:post, heartbeat_url).to_raise(Faraday::ConnectionFailed.new('refused'))

      expect { sender.send_heartbeat(status: 'running') }.not_to raise_error
    end

    it 'does not raise on timeout' do
      stub_request(:post, heartbeat_url).to_timeout

      expect { sender.send_heartbeat(status: 'running') }.not_to raise_error
    end
  end

  # The smoke-test profile no longer stubs the heartbeat (#830): the orchestrator
  # full-flow loopback needs the real POST to prove the callback path. enabled?
  # (CALLBACK_URL presence) is the sole control — the staging CI smoke sets no
  # CALLBACK_URL, so heartbeats stay silent there without a stub.
  describe 'POSTs regardless of SCAN_PROFILE (#830)' do
    it 'POSTs the heartbeat even when SCAN_PROFILE is smoke-test' do
      stub_const('ENV', ENV.to_h.merge('SCAN_PROFILE' => 'smoke-test'))
      stub = stub_request(:post, heartbeat_url).to_return(status: 200)

      sender.send_heartbeat(status: 'running')

      expect(stub).to have_been_requested
    end
  end

  # When no CALLBACK_URL is configured (CI smoke launched via trigger-scan.sh),
  # the derived URL is host-less; send_heartbeat must no-op rather than POST to
  # nil:80 (the rescued-but-noisy regression #830 introduced by dropping the stub).
  describe 'no CALLBACK_URL' do
    let(:sender) do
      described_class.new(callback_url: '', scan_uuid: 's', job_id: 'j', callback_secret: 'x')
    end

    it 'makes no HTTP request' do
      sender.send_heartbeat(status: 'running')
      expect(WebMock).not_to have_requested(:post, //)
    end
  end

  describe '.enabled?' do
    it 'returns true when CALLBACK_URL is set' do
      stub_const('ENV', ENV.to_h.merge('CALLBACK_URL' => 'https://reporter.example.com/callbacks/scan_complete'))
      expect(described_class.enabled?).to be true
    end

    it 'returns false when CALLBACK_URL is not set' do
      stub_const('ENV', ENV.to_h.except('CALLBACK_URL'))
      expect(described_class.enabled?).to be false
    end
  end
end
