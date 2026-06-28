require 'sequel_helper'

RSpec.describe NotificationService do
  let(:target) { create(:target, name: 'Test App') }
  let(:scan) do
    create(:scan, :completed, target:, profile: 'standard',
                              summary: { 'total_findings' => 10, 'by_severity' => { 'critical' => 2, 'high' => 3, 'medium' => 4, 'low' => 1 } })
  end
  let(:service) { described_class.new(scan) }

  describe '#notify' do
    context 'when webhook is configured' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return('https://hooks.slack.com/test')
        allow(ENV).to receive(:fetch).with('SLACK_WEBHOOK_URL', nil).and_return('https://hooks.slack.com/test')
      end

      it 'sends a webhook POST request' do
        stub_request(:post, 'https://hooks.slack.com/test')
          .to_return(status: 200, body: 'ok')

        service.notify

        expect(WebMock).to have_requested(:post, 'https://hooks.slack.com/test')
      end

      it 'sends correct Slack payload structure' do
        stub = stub_request(:post, 'https://hooks.slack.com/test')
               .to_return(status: 200, body: 'ok')

        service.notify

        expect(stub).to have_been_requested
        expect(WebMock).to have_requested(:post, 'https://hooks.slack.com/test')
          .with(headers: { 'Content-Type' => 'application/json' })
      end

      it 'includes scan target name and findings in payload' do
        stub = stub_request(:post, 'https://hooks.slack.com/test')
               .with do |request|
                 body = JSON.parse(request.body)
                 body['text'].include?('Test App') &&
                   body['blocks'].any? { |b| b['type'] == 'header' }
               end
               .to_return(status: 200, body: 'ok')

        service.notify

        expect(stub).to have_been_requested
      end
    end

    context 'when webhook is not configured' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return(nil)
      end

      it 'does nothing without error' do
        expect { service.notify }.not_to raise_error
      end
    end

    context 'when notification fails' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return('https://hooks.slack.com/test')
        allow(ENV).to receive(:fetch).with('SLACK_WEBHOOK_URL', nil).and_return('https://hooks.slack.com/test')
      end

      it 'logs the error and does not raise' do
        stub_request(:post, 'https://hooks.slack.com/test')
          .to_raise(Faraday::ConnectionFailed.new('connection refused'))

        expect(Penetrator.logger).to receive(:error).with(/Notification failed/)

        expect { service.notify }.not_to raise_error
      end
    end
  end
end
