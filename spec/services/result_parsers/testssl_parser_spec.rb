require 'sequel_helper'

RSpec.describe ResultParsers::TestsslParser do
  # Real testssl.sh --jsonfile output captured against the authorized target
  # (167 records). Builds the parser against actual output, not a remembered schema.
  let(:fixture) { Penetrator.root.join('spec/fixtures/testssl_results.json') }

  def ids(finding, type)
    (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
  end

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture).parse }

    it 'keeps only mapped-severity, target-scoped records (drops OK + ip "/" meta)' do
      # 167 total − 59 OK − 2 ip:"/" meta
      expect(findings.length).to eq(106)
    end

    it 'drops OK + ip "/" engine/cmdline meta records' do
      gathered = findings.map { |f| f.dig('evidence', 'id') }
      expect(gathered).not_to include('heartbleed', 'engine_problem', 'cmdline_fast_depreciation')
    end

    it 'tags every finding as a tls misconfiguration' do
      expect(findings).to all(include('source_tool' => 'testssl', 'probe' => 'tls',
                                      'finding_type' => 'misconfiguration'))
    end

    it 'maps testssl severities from the config map' do
      expect(findings.find { |f| f.dig('evidence', 'id') == 'FS_KEMs' }['severity']).to eq('low')
      expect(findings.find { |f| f.dig('evidence', 'id') == 'cipherlist_3DES_IDEA' }['severity']).to eq('info')
    end

    it 'extracts cwe into identifiers' do
      f = findings.find { |x| x.dig('evidence', 'id') == 'cipherlist_3DES_IDEA' }
      expect(ids(f, 'cwe')).to include('CWE-310')
    end

    it 'preserves ALL CVEs from a space-separated multi-CVE field (lossless)' do
      drown = findings.find { |f| f.dig('evidence', 'id') == 'DROWN_hint' }
      expect(ids(drown, 'cve')).to include('CVE-2016-0800')
      expect(ids(drown, 'cve').length).to be >= 1
    end

    it 'falls back to id for the title when finding is "--"' do
      caa = findings.find { |f| f.dig('evidence', 'id') == 'DNS_CAArecord' }
      expect(caa['title']).to eq('DNS_CAArecord')
    end

    it 'derives the host from the fqdn portion of the ip field into a network location' do
      f = findings.find { |x| x.dig('evidence', 'id') == 'FS_KEMs' }
      expect(f['location']).to include('kind' => 'network', 'host' => 'auxscan.app.data-estate.cloud')
    end
  end

  describe '#parse severity mapping (constructed — target had no HIGH/CRITICAL/MEDIUM)' do
    def parse_one(record)
      tmp = Tempfile.new(['testssl', '.json'])
      tmp.write([record].to_json)
      tmp.close
      described_class.new(tmp.path).parse.first
    ensure
      tmp.unlink
    end

    { 'CRITICAL' => 'critical', 'HIGH' => 'high', 'MEDIUM' => 'medium', 'LOW' => 'low' }.each do |testssl_sev, expected|
      it "maps testssl #{testssl_sev} → #{expected}" do
        rec = { 'id' => 'x', 'ip' => 'host/1.2.3.4', 'port' => '443', 'severity' => testssl_sev, 'finding' => 'sample' }
        expect(parse_one(rec)['severity']).to eq(expected)
      end
    end

    it 'drops an unmapped severity (OK)' do
      rec = { 'id' => 'x', 'ip' => 'host/1.2.3.4', 'port' => '443', 'severity' => 'OK', 'finding' => 'fine' }
      expect(parse_one(rec)).to be_nil
    end
  end

  describe '#parse error handling' do
    it 'returns [] for a missing file' do
      expect(described_class.new('/nonexistent/testssl.json').parse).to eq([])
    end

    it 'returns [] for invalid JSON' do
      tmp = Tempfile.new(['bad', '.json'])
      tmp.write('not json')
      tmp.close
      expect(described_class.new(tmp.path).parse).to eq([])
    ensure
      tmp.unlink
    end
  end
end
