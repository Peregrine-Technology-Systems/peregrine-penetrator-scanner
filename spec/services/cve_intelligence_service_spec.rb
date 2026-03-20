require 'rails_helper'

RSpec.describe CveIntelligenceService do
  let(:service) { described_class.new }

  let(:api_responses) do
    {
      nvd: {
        'vulnerabilities' => [{
          'cve' => {
            'id' => 'CVE-2021-44228',
            'descriptions' => [{ 'lang' => 'en', 'value' => 'Log4j RCE vulnerability' }],
            'metrics' => {
              'cvssMetricV31' => [{
                'cvssData' => { 'baseScore' => 10.0 }
              }]
            },
            'references' => [
              { 'url' => 'https://nvd.nist.gov/vuln/detail/CVE-2021-44228', 'source' => 'nvd', 'tags' => ['Vendor Advisory'] }
            ],
            'configurations' => [{
              'nodes' => [{
                'cpeMatch' => [
                  { 'vulnerable' => true, 'criteria' => 'cpe:2.3:a:apache:log4j:*:*:*:*:*:*:*:*' }
                ]
              }]
            }]
          }
        }]
      },
      epss: {
        'data' => [{
          'cve' => 'CVE-2021-44228',
          'epss' => '0.975',
          'percentile' => '0.999'
        }]
      },
      kev: {
        'vulnerabilities' => [
          { 'cveID' => 'CVE-2021-44228' },
          { 'cveID' => 'CVE-2021-26855' }
        ]
      }
    }
  end

  describe '#enrich_finding' do
    let(:scan) { create(:scan, :running) }
    let(:finding) do
      create(:finding, scan:, source_tool: 'nuclei', severity: 'critical',
                       title: 'Log4Shell', cve_id: 'CVE-2021-44228',
                       evidence: { 'description' => 'test' })
    end

    before do
      stub_request(:get, /services.nvd.nist.gov/)
        .to_return(status: 200, body: api_responses[:nvd].to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, /api.first.org/)
        .to_return(status: 200, body: api_responses[:epss].to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, /www.cisa.gov/)
        .to_return(status: 200, body: api_responses[:kev].to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'enriches the finding with CVSS score' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.cvss_score).to eq(10.0)
    end

    it 'enriches the finding with EPSS score' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.epss_score).to eq(0.975)
    end

    it 'sets kev_known_exploited when CVE is in KEV catalog' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.kev_known_exploited).to be true
    end

    it 'adds NVD description to evidence' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.evidence['nvd_description']).to eq('Log4j RCE vulnerability')
    end

    it 'adds NVD references to evidence' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.evidence['nvd_references']).to be_an(Array)
    end

    it 'adds affected products to evidence' do
      service.enrich_finding(finding)
      finding.reload
      expect(finding.evidence['affected_products']).to include(/apache:log4j/)
    end

    it 'skips findings without CVE ID' do
      finding_no_cve = create(:finding, scan:, source_tool: 'zap', severity: 'medium',
                                        title: 'Missing Header', cve_id: nil)

      expect { service.enrich_finding(finding_no_cve) }.not_to raise_error
      # No HTTP requests should be made
    end

    it 'handles NVD API failures gracefully' do
      stub_request(:get, /services.nvd.nist.gov/).to_return(status: 500)

      expect { service.enrich_finding(finding) }.not_to raise_error
    end

    it 'handles EPSS API failures gracefully' do
      stub_request(:get, /api.first.org/).to_return(status: 500)

      expect { service.enrich_finding(finding) }.not_to raise_error
    end

    it 'falls back to CVSS v3.0 when v3.1 is not available' do
      nvd_v30 = api_responses[:nvd].deep_dup
      nvd_v30['vulnerabilities'][0]['cve']['metrics'] = {
        'cvssMetricV30' => [{ 'cvssData' => { 'baseScore' => 9.8 } }]
      }
      stub_request(:get, /services.nvd.nist.gov/)
        .to_return(status: 200, body: nvd_v30.to_json, headers: { 'Content-Type' => 'application/json' })

      service.enrich_finding(finding)
      finding.reload
      expect(finding.cvss_score).to eq(9.8)
    end

    it 'falls back to CVSS v2 when v3 is not available' do
      nvd_v2 = api_responses[:nvd].deep_dup
      nvd_v2['vulnerabilities'][0]['cve']['metrics'] = {
        'cvssMetricV2' => [{ 'cvssData' => { 'baseScore' => 7.5 } }]
      }
      stub_request(:get, /services.nvd.nist.gov/)
        .to_return(status: 200, body: nvd_v2.to_json, headers: { 'Content-Type' => 'application/json' })

      service.enrich_finding(finding)
      finding.reload
      expect(finding.cvss_score).to eq(7.5)
    end
  end

  describe '#enrich_scan' do
    let(:scan) { create(:scan, :running) }

    before do
      stub_request(:get, /services.nvd.nist.gov/)
        .to_return(status: 200, body: api_responses[:nvd].to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, /api.first.org/)
        .to_return(status: 200, body: api_responses[:epss].to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, /www.cisa.gov/)
        .to_return(status: 200, body: api_responses[:kev].to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'enriches all findings with CVE IDs' do
      f1 = create(:finding, scan:, source_tool: 'nuclei', severity: 'high',
                            title: 'CVE Finding', cve_id: 'CVE-2021-44228',
                            evidence: { 'description' => 'test' })
      create(:finding, scan:, source_tool: 'zap', severity: 'low',
                       title: 'No CVE Finding', cve_id: nil)

      # Stub sleep to avoid rate limiting delay in tests
      allow(service).to receive(:sleep)

      service.enrich_scan(scan)

      f1.reload
      expect(f1.cvss_score).to be_present
    end
  end

  describe 'KEV caching' do
    before do
      stub_request(:get, /www.cisa.gov/)
        .to_return(status: 200, body: api_responses[:kev].to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'caches KEV catalog for 1 hour' do
      kev_client = service.instance_variable_get(:@kev)
      kev_client.exploited?('CVE-2021-44228')
      kev_client.exploited?('CVE-2021-26855')

      # Should only fetch once due to caching
      expect(WebMock).to have_requested(:get, /www.cisa.gov/).once
    end
  end

  describe '#query_osv' do
    let(:osv_response) do
      {
        'vulns' => [{
          'id' => 'GHSA-1234-5678-9012',
          'summary' => 'Test vulnerability in test gem',
          'aliases' => ['CVE-2021-12345'],
          'references' => [{ 'url' => 'https://github.com/advisory' }],
          'database_specific' => { 'severity' => 'HIGH' }
        }]
      }
    end

    it 'returns vulnerabilities for a package' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_return(status: 200, body: osv_response.to_json, headers: { 'Content-Type' => 'application/json' })

      results = service.query_osv('rails')

      expect(results.length).to eq(1)
      expect(results.first[:id]).to eq('GHSA-1234-5678-9012')
      expect(results.first[:severity]).to eq('high')
    end

    it 'returns empty array on failure' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_return(status: 500)

      results = service.query_osv('rails')
      expect(results).to eq([])
    end

    it 'handles network errors gracefully' do
      stub_request(:post, 'https://api.osv.dev/v1/query')
        .to_raise(Faraday::ConnectionFailed.new('connection refused'))

      results = service.query_osv('rails')
      expect(results).to eq([])
    end
  end
end
