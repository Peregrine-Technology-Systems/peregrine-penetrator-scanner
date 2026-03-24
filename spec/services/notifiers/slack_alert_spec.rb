require 'sequel_helper'

RSpec.describe Notifiers::SlackAlert do
  let(:scan) { create(:scan) }

  before do
    described_class.reset_debounce!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return('https://hooks.slack.com/test')
    allow(ENV).to receive(:fetch).with('SLACK_WEBHOOK_URL', nil).and_return('https://hooks.slack.com/test')
  end

  describe '.send_alert' do
    it 'posts a warning to Slack for rate limiting' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .to_return(status: 200, body: 'ok')

      described_class.send_alert(
        scan:, tool: 'nuclei', severity: :warning,
        message: 'Receiving HTTP 429 responses',
        action: 'Consider reducing rate_limit in scan profile'
      )

      expect(stub).to have_been_requested
    end

    it 'posts an error to Slack for tool failures' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .to_return(status: 200, body: 'ok')

      described_class.send_alert(
        scan:, tool: 'zap', severity: :error,
        message: 'Failed to start ZAP',
        action: 'Check Docker image has ZAP installed'
      )

      expect(stub).to have_been_requested
    end

    it 'includes tool name, target, and action in payload' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .with do |req|
               body = JSON.parse(req.body)
               body['text'].include?('nuclei') &&
                 body['blocks'].any? { |b| b.dig('text', 'text')&.include?('429') }
             end
             .to_return(status: 200, body: 'ok')

      described_class.send_alert(
        scan:, tool: 'nuclei', severity: :warning,
        message: 'HTTP 429 responses',
        action: 'Reduce rate_limit'
      )

      expect(stub).to have_been_requested
    end

    it 'does nothing when SLACK_WEBHOOK_URL is not set' do
      allow(ENV).to receive(:fetch).with('SLACK_WEBHOOK_URL', nil).and_return(nil)

      expect { described_class.send_alert(scan:, tool: 'zap', severity: :error, message: 'fail') }
        .not_to raise_error

      expect(WebMock).not_to have_requested(:post, 'https://hooks.slack.com/test')
    end

    it 'debounces repeated alerts for the same tool and scan' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .to_return(status: 200, body: 'ok')

      3.times do
        described_class.send_alert(scan:, tool: 'nuclei', severity: :warning, message: '429')
      end

      expect(stub).to have_been_requested.once
    end

    it 'allows alerts for different tools' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .to_return(status: 200, body: 'ok')

      described_class.send_alert(scan:, tool: 'nuclei', severity: :warning, message: '429')
      described_class.send_alert(scan:, tool: 'zap', severity: :error, message: 'failed')

      expect(stub).to have_been_requested.twice
    end
  end
end
