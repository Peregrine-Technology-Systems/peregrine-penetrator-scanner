require 'sequel_helper'

RSpec.describe Notifiers::SlackNotifier do
  let(:scan) { create(:scan) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return('https://hooks.slack.com/test')
    allow(ENV).to receive(:fetch).with('SLACK_WEBHOOK_URL', nil).and_return('https://hooks.slack.com/test')
  end

  describe '.send_started' do
    it 'posts a scan-started notification to Slack' do
      stub = stub_request(:post, 'https://hooks.slack.com/test')
             .to_return(status: 200, body: 'ok')

      described_class.send_started(scan)

      expect(stub).to have_been_requested
      expect(WebMock).to have_requested(:post, 'https://hooks.slack.com/test')
        .with { |req| req.body.include?('Scan Started') }
    end

    it 'includes target name and profile' do
      stub_request(:post, 'https://hooks.slack.com/test')
        .to_return(status: 200, body: 'ok')

      described_class.send_started(scan)

      expect(WebMock).to have_requested(:post, 'https://hooks.slack.com/test')
        .with { |req| req.body.include?(scan.target.name) && req.body.include?(scan.profile) }
    end

    it 'does nothing when SLACK_WEBHOOK_URL is not set' do
      allow(ENV).to receive(:[]).with('SLACK_WEBHOOK_URL').and_return(nil)

      described_class.send_started(scan)

      expect(WebMock).not_to have_requested(:post, 'https://hooks.slack.com/test')
    end

    it 'does not raise on Slack failure' do
      stub_request(:post, 'https://hooks.slack.com/test')
        .to_return(status: 500, body: 'error')

      expect { described_class.send_started(scan) }.not_to raise_error
    end
  end
end
