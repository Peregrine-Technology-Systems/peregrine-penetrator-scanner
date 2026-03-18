require 'rails_helper'

RSpec.describe CveClients::EpssClient do
  let(:http) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end
  end
  let(:client) { described_class.new(http) }

  describe '#fetch' do
    it 'returns EPSS data on success' do
      response_body = { 'data' => [{ 'cve' => 'CVE-2021-44228', 'epss' => '0.975' }] }
      stub_request(:get, /api.first.org/)
        .to_return(status: 200, body: response_body.to_json, headers: { 'Content-Type' => 'application/json' })

      result = client.fetch('CVE-2021-44228')
      expect(result['epss']).to eq('0.975')
    end

    it 'returns nil on failure' do
      stub_request(:get, /api.first.org/).to_return(status: 500)

      expect(client.fetch('CVE-2021-44228')).to be_nil
    end

    it 'returns nil on network error' do
      stub_request(:get, /api.first.org/).to_raise(Faraday::ConnectionFailed.new('timeout'))

      expect(client.fetch('CVE-2021-44228')).to be_nil
    end
  end
end
