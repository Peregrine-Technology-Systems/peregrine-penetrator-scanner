require 'rails_helper'

RSpec.describe Trackers::GithubTracker do
  let(:tracker) { described_class.new(owner: 'test-org', repo: 'test-repo', token: 'ghp_test123') }
  let(:scan) { create(:scan, :completed) }

  let(:finding) do
    create(:finding, scan:, severity: 'high', title: 'SQL Injection in login',
                     source_tool: 'sqlmap', url: 'https://example.com/login',
                     cwe_id: 'CWE-89', cve_id: 'CVE-2024-1234',
                     fingerprint: SecureRandom.hex(32),
                     ai_assessment: { 'remediation' => 'Use parameterized queries' })
  end

  let(:github_api_url) { 'https://api.github.com/repos/test-org/test-repo/issues' }

  describe '#create_issue' do
    it 'creates a GitHub issue with correct payload' do
      stub = stub_request(:post, github_api_url)
             .with(body: hash_including(
               'title' => '[HIGH] SQL Injection in login',
               'labels' => %w[pentest high]
             ))
             .to_return(status: 201, body: { number: 42, html_url: 'https://github.com/test-org/test-repo/issues/42' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      result = tracker.create_issue(finding, 'Test App')

      expect(stub).to have_been_requested
      expect(result[:ticket_ref]).to eq('test-org/test-repo#42')
      expect(result[:ticket_url]).to eq('https://github.com/test-org/test-repo/issues/42')
    end

    it 'includes remediation in the body' do
      stub = stub_request(:post, github_api_url)
             .with(body: /parameterized queries/)
             .to_return(status: 201, body: { number: 1, html_url: 'https://example.com' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      tracker.create_issue(finding, 'Test App')
      expect(stub).to have_been_requested
    end

    it 'includes CWE and CVE links in the body' do
      stub = stub_request(:post, github_api_url)
             .with(body: /CWE-89.*CVE-2024-1234/m)
             .to_return(status: 201, body: { number: 1, html_url: 'https://example.com' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      tracker.create_issue(finding, 'Test App')
      expect(stub).to have_been_requested
    end

    it 'returns nil on API failure' do
      stub_request(:post, github_api_url).to_return(status: 422, body: '{}')

      result = tracker.create_issue(finding, 'Test App')
      expect(result).to be_nil
    end

    it 'returns nil and logs on network error' do
      stub_request(:post, github_api_url).to_raise(Faraday::ConnectionFailed)

      expect(Rails.logger).to receive(:error).with(/GithubTracker/)
      result = tracker.create_issue(finding, 'Test App')
      expect(result).to be_nil
    end
  end

  describe '.configured?' do
    it 'returns true with valid config' do
      target = build(:target, :with_github_tickets)
      expect(described_class.configured?(target)).to be true
    end

    it 'returns false when config is nil' do
      target = build(:target, ticket_config: nil)
      expect(described_class.configured?(target)).to be false
    end

    it 'returns false when required keys are missing' do
      target = build(:target, ticket_config: { 'owner' => 'org' })
      expect(described_class.configured?(target)).to be false
    end
  end
end
