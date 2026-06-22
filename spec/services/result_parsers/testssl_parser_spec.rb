require 'sequel_helper'

RSpec.describe ResultParsers::TestsslParser do
  # Real testssl.sh --jsonfile output captured against the authorized target
  # auxscan.app.data-estate.cloud (167 records). Builds the parser against actual
  # output, not a remembered schema (the canned smoke does not exercise this tool).
  let(:fixture) { Penetrator.root.join('spec/fixtures/testssl_results.json') }

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture).parse }

    it 'keeps only mapped-severity, target-scoped records (drops OK + ip "/" meta)' do
      # 167 total − 59 OK − 2 ip:"/" meta (engine_problem, cmdline_fast_depreciation)
      expect(findings.length).to eq(106)
    end

    it 'drops OK records (secure/pass — not findings)' do
      expect(findings.map { |f| f[:evidence][:id] }).not_to include('heartbleed')
    end

    it 'drops ip "/" engine/cmdline meta records' do
      expect(findings.map { |f| f[:evidence][:id] }).not_to include('engine_problem', 'cmdline_fast_depreciation')
    end

    it 'tags every finding with source_tool testssl' do
      expect(findings.map { |f| f[:source_tool] }.uniq).to eq(['testssl'])
    end

    it 'maps testssl LOW → low' do
      kems = findings.find { |f| f[:evidence][:id] == 'FS_KEMs' }
      expect(kems[:severity]).to eq('low')
    end

    it 'maps testssl INFO → info' do
      info = findings.find { |f| f[:evidence][:id] == 'cipherlist_3DES_IDEA' }
      expect(info[:severity]).to eq('info')
    end

    it 'extracts cwe_id' do
      f = findings.find { |x| x[:evidence][:id] == 'cipherlist_3DES_IDEA' }
      expect(f[:cwe_id]).to eq('CWE-310')
    end

    it 'extracts the first cve_id from a space-separated multi-CVE field' do
      drown = findings.find { |f| f[:evidence][:id] == 'DROWN_hint' }
      expect(drown[:cve_id]).to eq('CVE-2016-0800')
    end

    it 'falls back to id for the title when finding is "--"' do
      caa = findings.find { |f| f[:evidence][:id] == 'DNS_CAArecord' }
      expect(caa[:title]).to eq('DNS_CAArecord')
    end

    it 'derives url from the fqdn portion of the ip field' do
      f = findings.find { |x| x[:evidence][:id] == 'FS_KEMs' }
      expect(f[:url]).to eq('https://auxscan.app.data-estate.cloud')
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

    {
      'CRITICAL' => 'critical', 'HIGH' => 'high', 'MEDIUM' => 'medium', 'LOW' => 'low'
    }.each do |testssl_sev, expected|
      it "maps testssl #{testssl_sev} → #{expected}" do
        rec = { 'id' => 'x', 'ip' => 'host/1.2.3.4', 'port' => '443',
                'severity' => testssl_sev, 'finding' => 'sample' }
        expect(parse_one(rec)[:severity]).to eq(expected)
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
