require 'sequel_helper'

RSpec.describe ResultParsers::RetirejsParser do
  # Real retire.js --outputformat json output captured by scanning jQuery 1.12.4
  # (a known-vulnerable version). 6 vulnerabilities across one file.
  let(:fixture) { Penetrator.root.join('spec/fixtures/retirejs_results.json') }

  def ids(finding, type)
    (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
  end

  def by_summary(findings, frag)
    findings.find { |x| x.dig('evidence', 'identifiers_summary').to_s.include?(frag) }
  end

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture, 'https://example.com').parse }

    it 'produces one contract finding per vulnerability (6 in fixture)' do
      expect(findings.length).to eq(6)
      expect(findings).to all(include('source_tool' => 'retirejs', 'probe' => 'sca',
                                      'finding_type' => 'outdated-component'))
    end

    it 'maps retire.js severities' do
      expect(by_summary(findings, 'parseHTML')['severity']).to eq('medium')
      expect(by_summary(findings, 'End-of-Life')['severity']).to eq('low')
    end

    it 'preserves CVE identifiers (lossless)' do
      expect(ids(by_summary(findings, 'CORS'), 'cve')).to include('CVE-2015-9251')
      expect(ids(by_summary(findings, 'parseHTML'), 'cve')).to be_empty
    end

    it 'preserves CWE identifiers' do
      expect(ids(by_summary(findings, 'parseHTML'), 'cwe')).to include('CWE-79')
    end

    it 'uses identifiers.summary as title' do
      expect(by_summary(findings, 'parseHTML')['title']).to include('parseHTML')
    end

    it 'records the vulnerable library in a package location + component block' do
      f = findings.first
      expect(f['location']).to include('kind' => 'package', 'name' => 'jquery', 'version' => '1.12.4')
      expect(f['component']).to include('name' => 'jquery', 'version' => '1.12.4', 'ecosystem' => 'npm')
    end

    it 'keeps the affected target URL in evidence' do
      expect(findings.map { |f| f.dig('evidence', 'affected_url') }.uniq).to eq(['https://example.com'])
    end
  end

  describe '#parse error handling' do
    it 'returns [] for a missing file' do
      expect(described_class.new('/nonexistent.json', 'https://x.com').parse).to eq([])
    end

    it 'returns [] for invalid JSON' do
      tmp = Tempfile.new(['bad', '.json'])
      tmp.write('not json')
      tmp.close
      expect(described_class.new(tmp.path, 'https://x.com').parse).to eq([])
    ensure
      tmp.unlink
    end

    it 'returns [] when data array is empty (no vulns)' do
      tmp = Tempfile.new(['empty', '.json'])
      tmp.write('{"version":"5.4.3","data":[],"messages":[],"errors":[],"time":0.1}')
      tmp.close
      expect(described_class.new(tmp.path, 'https://x.com').parse).to eq([])
    ensure
      tmp.unlink
    end
  end
end
