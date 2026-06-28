require 'sequel_helper'

RSpec.describe CveClients::KevClient do
  let(:http) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end
  end
  let(:client) { described_class.new(http) }

  let(:kev_response) do
    {
      'vulnerabilities' => [
        { 'cveID' => 'CVE-2021-44228' },
        { 'cveID' => 'CVE-2021-26855' }
      ]
    }
  end

  before do
    stub_request(:get, /www.cisa.gov/)
      .to_return(status: 200, body: kev_response.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '#exploited?' do
    it 'returns true for known exploited CVEs' do
      expect(client.exploited?('CVE-2021-44228')).to be true
    end

    it 'returns false for unknown CVEs' do
      expect(client.exploited?('CVE-9999-99999')).to be false
    end

    it 'caches results across calls' do
      client.exploited?('CVE-2021-44228')
      client.exploited?('CVE-2021-26855')

      expect(WebMock).to have_requested(:get, /www.cisa.gov/).once
    end

    it 'returns false when API fails' do
      stub_request(:get, /www.cisa.gov/).to_return(status: 500)

      expect(client.exploited?('CVE-2021-44228')).to be false
    end

    it 'returns cached data on subsequent API failure' do
      # First call succeeds and caches
      client.exploited?('CVE-2021-44228')

      # Expire cache
      client.instance_variable_set(:@cache_time, 2.hours.ago)

      # Second call fails
      stub_request(:get, /www.cisa.gov/).to_raise(Faraday::ConnectionFailed.new('timeout'))

      expect(client.exploited?('CVE-2021-44228')).to be true
    end
  end
end
