require 'rails_helper'

RSpec.describe CveClients::NvdClient do
  let(:http) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end
  end
  let(:client) { described_class.new(http) }

  let(:cve_data) do
    {
      'metrics' => {
        'cvssMetricV31' => [{ 'cvssData' => { 'baseScore' => 10.0 } }],
        'cvssMetricV30' => [{ 'cvssData' => { 'baseScore' => 9.8 } }],
        'cvssMetricV2' => [{ 'cvssData' => { 'baseScore' => 7.5 } }]
      },
      'descriptions' => [
        { 'lang' => 'en', 'value' => 'A critical vulnerability' }
      ],
      'references' => [
        { 'url' => 'https://example.com', 'source' => 'test', 'tags' => ['Vendor Advisory'] }
      ],
      'configurations' => [{
        'nodes' => [{
          'cpeMatch' => [
            { 'vulnerable' => true, 'criteria' => 'cpe:2.3:a:vendor:product:*' },
            { 'vulnerable' => false, 'criteria' => 'cpe:2.3:a:vendor:other:*' }
          ]
        }]
      }]
    }
  end

  let(:nvd_response) do
    { 'vulnerabilities' => [{ 'cve' => cve_data }] }
  end

  describe '#fetch' do
    it 'returns CVE data on success' do
      stub_request(:get, /services.nvd.nist.gov/)
        .to_return(status: 200, body: nvd_response.to_json, headers: { 'Content-Type' => 'application/json' })

      result = client.fetch('CVE-2021-44228')
      expect(result).to eq(cve_data)
    end

    it 'returns nil on failure' do
      stub_request(:get, /services.nvd.nist.gov/).to_return(status: 500)

      expect(client.fetch('CVE-2021-44228')).to be_nil
    end

    it 'returns nil on network error' do
      stub_request(:get, /services.nvd.nist.gov/).to_raise(Faraday::ConnectionFailed.new('timeout'))

      expect(client.fetch('CVE-2021-44228')).to be_nil
    end

    it 'sends API key header when configured' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('NVD_API_KEY').and_return('test-key')
      allow(ENV).to receive(:fetch).and_call_original

      stub_request(:get, /services.nvd.nist.gov/)
        .with(headers: { 'apiKey' => 'test-key' })
        .to_return(status: 200, body: nvd_response.to_json, headers: { 'Content-Type' => 'application/json' })

      client.fetch('CVE-2021-44228')
      expect(WebMock).to have_requested(:get, /services.nvd.nist.gov/).with(headers: { 'apiKey' => 'test-key' })
    end
  end

  describe '#extract_cvss' do
    it 'prefers CVSS v3.1' do
      expect(client.extract_cvss(cve_data)).to eq(10.0)
    end

    it 'falls back to v3.0' do
      data = cve_data.merge('metrics' => {
        'cvssMetricV30' => [{ 'cvssData' => { 'baseScore' => 9.8 } }]
      })
      expect(client.extract_cvss(data)).to eq(9.8)
    end

    it 'falls back to v2' do
      data = cve_data.merge('metrics' => {
        'cvssMetricV2' => [{ 'cvssData' => { 'baseScore' => 7.5 } }]
      })
      expect(client.extract_cvss(data)).to eq(7.5)
    end

    it 'returns nil when no metrics' do
      expect(client.extract_cvss({ 'metrics' => {} })).to be_nil
    end
  end

  describe '#extract_description' do
    it 'returns English description' do
      expect(client.extract_description(cve_data)).to eq('A critical vulnerability')
    end

    it 'returns nil when no descriptions' do
      expect(client.extract_description({ 'descriptions' => [] })).to be_nil
    end
  end

  describe '#extract_references' do
    it 'maps references to structured data' do
      refs = client.extract_references(cve_data)
      expect(refs.first).to include(url: 'https://example.com', source: 'test')
    end
  end

  describe '#extract_affected_products' do
    it 'returns only vulnerable CPE criteria' do
      products = client.extract_affected_products(cve_data)
      expect(products).to eq(['cpe:2.3:a:vendor:product:*'])
    end
  end
end
