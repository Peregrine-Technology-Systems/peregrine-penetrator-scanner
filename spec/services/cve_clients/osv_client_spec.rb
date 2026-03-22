require 'sequel_helper'

RSpec.describe CveClients::OsvClient do
  let(:http) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end
  end
  let(:client) { described_class.new(http) }

  let(:osv_response) do
    {
      'vulns' => [{
        'id' => 'GHSA-1234-5678-9012',
        'summary' => 'Test vulnerability',
        'aliases' => ['CVE-2021-12345'],
        'references' => [{ 'url' => 'https://github.com/advisory' }],
        'database_specific' => { 'severity' => 'HIGH' }
      }]
    }
  end

  describe '#query' do
    it 'returns structured vulnerability data' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_return(status: 200, body: osv_response.to_json, headers: { 'Content-Type' => 'application/json' })

      results = client.query('rails')
      expect(results.length).to eq(1)
      expect(results.first[:id]).to eq('GHSA-1234-5678-9012')
      expect(results.first[:severity]).to eq('high')
      expect(results.first[:aliases]).to eq(['CVE-2021-12345'])
    end

    it 'includes version in payload when provided' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .with(body: hash_including('version' => '7.0.0'))
        .to_return(status: 200, body: { 'vulns' => [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      client.query('rails', version: '7.0.0')
      expect(WebMock).to have_requested(:post, 'https://api.osv.dev/v1/query')
        .with(body: hash_including('version' => '7.0.0'))
    end

    it 'returns empty array on failure' do
      stub_request(:post, 'https://api.osv.dev/v1/query').to_return(status: 500)

      expect(client.query('rails')).to eq([])
    end

    it 'returns empty array on network error' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_raise(Faraday::ConnectionFailed.new('connection refused'))

      expect(client.query('rails')).to eq([])
    end

    it 'extracts severity from CVSS score when database_specific is absent' do
      vuln_with_cvss = {
        'vulns' => [{
          'id' => 'GHSA-test',
          'summary' => 'Test',
          'severity' => [{ 'score' => 9.5 }],
          'references' => []
        }]
      }
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_return(status: 200, body: vuln_with_cvss.to_json, headers: { 'Content-Type' => 'application/json' })

      results = client.query('rails')
      expect(results.first[:severity]).to eq('critical')
    end
  end
end
