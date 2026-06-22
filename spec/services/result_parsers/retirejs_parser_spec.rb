require 'sequel_helper'

RSpec.describe ResultParsers::RetirejsParser do
  # Real retire.js --outputformat json output captured by scanning jQuery 1.12.4
  # (a known-vulnerable version) with `retire --path /tmp/retire-test --outputformat json`
  # 6 vulnerabilities across one file. Canned smoke does not exercise this tool.
  let(:fixture) { Penetrator.root.join('spec/fixtures/retirejs_results.json') }

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture, 'https://example.com').parse }

    it 'produces one finding per vulnerability (6 vulns in fixture)' do
      expect(findings.length).to eq(6)
    end

    it 'tags every finding with source_tool retirejs' do
      expect(findings.map { |f| f[:source_tool] }.uniq).to eq(['retirejs'])
    end

    it 'maps retire.js medium → medium' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('parseHTML') }
      expect(f[:severity]).to eq('medium')
    end

    it 'maps retire.js low → low' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('End-of-Life') }
      expect(f[:severity]).to eq('low')
    end

    it 'extracts cve_id (first CVE from identifiers.CVE array)' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('CORS') }
      expect(f[:cve_id]).to eq('CVE-2015-9251')
    end

    it 'sets cve_id to nil when identifiers.CVE is absent' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('parseHTML') }
      expect(f[:cve_id]).to be_nil
    end

    it 'extracts cwe_id (first entry from cwe array)' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('parseHTML') }
      expect(f[:cwe_id]).to eq('CWE-79')
    end

    it 'uses identifiers.summary as title' do
      f = findings.find { |x| x[:evidence][:identifiers_summary].include?('parseHTML') }
      expect(f[:title]).to include('parseHTML')
    end

    it 'sets url to the target_url passed at construction' do
      expect(findings.map { |f| f[:url] }.uniq).to eq(['https://example.com'])
    end

    it 'includes component + version in evidence' do
      f = findings.first
      expect(f[:evidence][:component]).to eq('jquery')
      expect(f[:evidence][:version]).to eq('1.12.4')
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
      tmp.write('{"version":"5.4.3","start":"2026-01-01T00:00:00.000Z","data":[],"messages":[],"errors":[],"time":0.1}')
      tmp.close
      expect(described_class.new(tmp.path, 'https://x.com').parse).to eq([])
    ensure
      tmp.unlink
    end
  end
end
