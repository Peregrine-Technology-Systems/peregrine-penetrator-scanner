# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScanCallbackService do
  let(:target) { create(:target, name: 'Test App', urls: ['https://example.com']) }
  let(:scan) do
    create(:scan, target:, profile: 'standard', status: 'completed',
                  started_at: 1.hour.ago, completed_at: Time.current,
                  summary: { 'total_findings' => 5, 'by_severity' => { 'high' => 2, 'medium' => 3 } })
  end
  let(:cost_logger) { ScanCostLogger.new(scan) }
  let(:callback_url) { 'https://api.peregrine-tech.com/internal/scans/abc-123/complete' }
  let(:callback_secret) { 'test-shared-secret-key' }

  before do
    stub_const('ENV', ENV.to_h.merge(
                        'CALLBACK_URL' => callback_url,
                        'SCAN_CALLBACK_SECRET' => callback_secret,
                        'SCAN_UUID' => 'abc-123'
                      ))
  end

  describe '#notify' do
    before { allow_any_instance_of(described_class).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

    it 'POSTs scan summary to the callback URL' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      result = service.notify

      expect(result).to be true
      expect(WebMock).to have_requested(:post, callback_url).once
    end

    it 'includes scan summary in the payload' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        body['scan_uuid'] == 'abc-123' &&
          body['status'] == 'completed' &&
          body['summary']['total_findings'] == 5
      end)
    end

    it 'includes cost data in the payload' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')
      cost_logger.track_anthropic_tokens(2000)

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        body['cost_data']['anthropic_tokens_used'] == 2000
      end)
    end

    it 'includes GCS report paths in the payload' do
      create(:report, scan:, format: 'pdf', gcs_path: 'reports/abc-123/report.pdf', status: 'completed')
      create(:report, scan:, format: 'html', gcs_path: 'reports/abc-123/report.html', status: 'completed')
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        body['gcs_report_paths'].length == 2
      end)
    end

    it 'authenticates with shared secret in Authorization header' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to have_requested(:post, callback_url).with(
        headers: { 'Authorization' => "Bearer #{callback_secret}" }
      )
    end

    it 'sends Content-Type application/json' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to have_requested(:post, callback_url).with(
        headers: { 'Content-Type' => 'application/json' }
      )
    end

    it 'retries up to 3 times on failure' do
      stub_request(:post, callback_url)
        .to_return(status: 500).then
        .to_return(status: 500).then
        .to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      result = service.notify

      expect(result).to be true
      expect(WebMock).to have_requested(:post, callback_url).times(3)
    end

    it 'returns false after exhausting retries' do
      stub_request(:post, callback_url).to_return(status: 500)

      service = described_class.new(scan, cost_logger)
      result = service.notify

      expect(result).to be false
      expect(WebMock).to have_requested(:post, callback_url).times(3)
    end

    it 'returns false and logs error on network failure' do
      stub_request(:post, callback_url).to_raise(Faraday::ConnectionFailed.new('connection refused'))

      service = described_class.new(scan, cost_logger)
      expect(Penetrator.logger).to receive(:error).with(/ScanCallbackService/).at_least(:once)
      result = service.notify

      expect(result).to be false
    end

    it 'skips callback when CALLBACK_URL is not set' do
      stub_const('ENV', ENV.to_h.except('CALLBACK_URL'))

      service = described_class.new(scan, cost_logger)
      result = service.notify

      expect(result).to be false
      expect(WebMock).not_to have_requested(:post, callback_url)
    end

    it 'includes gcs_scan_results_path when provided' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')
      gcs_path = 'scan-results/target-1/scan-1/scan_results.json'

      service = described_class.new(scan, cost_logger, gcs_scan_results_path: gcs_path)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        body['gcs_scan_results_path'] == gcs_path
      end)
    end

    it 'omits gcs_scan_results_path when not provided' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        !body.key?('gcs_scan_results_path')
      end)
    end

    it 'includes scan duration in the payload' do
      stub_request(:post, callback_url).to_return(status: 200, body: '{"ok":true}')

      service = described_class.new(scan, cost_logger)
      service.notify

      expect(WebMock).to(have_requested(:post, callback_url).with do |req|
        body = JSON.parse(req.body)
        body['duration_seconds'].is_a?(Numeric)
      end)
    end
  end

  describe '.enabled?' do
    it 'returns true when CALLBACK_URL is set' do
      expect(described_class.enabled?).to be true
    end

    it 'returns false when CALLBACK_URL is not set' do
      stub_const('ENV', ENV.to_h.except('CALLBACK_URL'))
      expect(described_class.enabled?).to be false
    end
  end
end
