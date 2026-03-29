require 'sequel_helper'

RSpec.describe HeartbeatSender do
  let(:sender) do
    described_class.new(
      callback_url: 'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
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

  describe '.stub_mode?' do
    it 'returns true when SCAN_PROFILE is smoke-test' do
      stub_const('ENV', ENV.to_h.merge('SCAN_PROFILE' => 'smoke-test'))
      expect(described_class.stub_mode?).to be true
    end

    it 'returns false for normal profiles' do
      stub_const('ENV', ENV.to_h.merge('SCAN_PROFILE' => 'standard'))
      expect(described_class.stub_mode?).to be false
    end
  end

  describe 'stub mode behavior' do
    before do
      stub_const('ENV', ENV.to_h.merge('SCAN_PROFILE' => 'smoke-test'))
    end

    it 'logs payload without making HTTP call' do
      expect(Penetrator.logger).to receive(:info).with(/STUB/)

      sender.send_heartbeat(status: 'running')

      expect(WebMock).not_to have_requested(:post, heartbeat_url)
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
