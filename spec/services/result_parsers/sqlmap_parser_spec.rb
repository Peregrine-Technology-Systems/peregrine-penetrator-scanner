require 'sequel_helper'

RSpec.describe ResultParsers::SqlmapParser do
  describe '#parse (structured --report-json, #822)' do
    let(:url) { 'http://vuln.test/artists.php?artist=1' }
    let(:report_path) { Penetrator.root.join('tmp/test_sqlmap_report.json') }
    let(:parser) { described_class.new(report_path, url) }
    let(:fixture) { Penetrator.root.join('spec/fixtures/sqlmap_report.json') }

    before { FileUtils.cp(fixture, report_path) }
    after { FileUtils.rm_f(report_path) }

    def ids(finding, type)
      (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
    end

    # The load-bearing silent-OK guard: a known-injectable fixture MUST yield findings.
    # If an upstream format change empties this, the test fails instead of prod silently
    # passing with zero findings.
    it 'yields one finding per technique from a known-injectable report' do
      results = parser.parse
      expect(results.length).to eq(3)
      expect(results).to all(include('source_tool' => 'sqlmap', 'probe' => 'injection',
                                     'finding_type' => 'vulnerability', 'severity' => 'high'))
    end

    it 'carries the injection technique into the title and tool_check_id' do
      types = parser.parse.map { |r| r['evidence']['injection_type'] }
      expect(types).to contain_exactly('boolean-based blind', 'time-based blind', 'UNION query')
      titles = parser.parse.map { |r| r['title'] }
      expect(titles).to include('SQL Injection (boolean-based blind)', 'SQL Injection (UNION query)')
      expect(parser.parse.map { |r| r['tool_check_id'] }).to include('time-based blind')
    end

    it 'carries the back-end DBMS into every finding' do
      expect(parser.parse).to all(satisfy { |r| r['evidence']['dbms'] == 'MySQL' })
    end

    it 'carries place, parameter, and payload into evidence' do
      finding = parser.parse.first
      expect(finding['evidence']).to include('place' => 'GET', 'parameter' => 'artist')
      expect(finding['evidence']['payload']).to be_present
    end

    it 'puts the parameter + url in a web location' do
      results = parser.parse
      expect(results).to all(satisfy { |r| r.dig('location', 'parameter') == 'artist' })
      expect(results).to all(satisfy { |r| r.dig('location', 'url') == url })
    end

    it 'tags CWE-89 in identifiers' do
      expect(parser.parse).to all(satisfy { |r| ids(r, 'cwe') == ['CWE-89'] })
    end

    context 'when injection.dbms is a list' do
      before do
        report = JSON.parse(File.read(fixture))
        report['data'][1]['value'][0]['dbms'] = %w[MySQL MariaDB]
        File.write(report_path, JSON.generate(report))
      end

      it 'joins the DBMS values' do
        expect(parser.parse.first['evidence']['dbms']).to eq('MySQL, MariaDB')
      end
    end

    context 'when injection.dbms is absent' do
      before do
        report = JSON.parse(File.read(fixture))
        report['data'][1]['value'][0].delete('dbms')
        File.write(report_path, JSON.generate(report))
      end

      it 'falls back to the DBMS_FINGERPRINT entry' do
        expect(parser.parse.first['evidence']['dbms']).to eq('MySQL >= 5.0.12')
      end
    end

    context 'when no injection was found (empty data — real sqlmap no-finding report)' do
      before do
        File.write(report_path, JSON.generate(
                                  { 'success' => true, 'data' => [], 'error' => [],
                                    'meta' => { 'api_version' => 2 } }
                                ))
      end

      it 'returns an empty array (a valid clean scan, not a failure)' do
        expect(parser.parse).to eq([])
      end
    end

    it 'returns empty when the report file does not exist' do
      expect(described_class.new(Pathname.new('/nonexistent/sqlmap.json'), url).parse).to eq([])
    end

    context 'with silent-OK guards (loud on drift, not empty)' do
      it 'raises when the report JSON is malformed' do
        File.write(report_path, 'not json{')
        expect { parser.parse }.to raise_error(described_class::MalformedReport, /malformed sqlmap report JSON/)
      end

      it 'raises when the envelope has no data array (schema drift)' do
        File.write(report_path, JSON.generate({ 'success' => true, 'results' => [] }))
        expect { parser.parse }.to raise_error(described_class::MalformedReport, /unexpected report envelope/)
      end

      it 'raises when injection points are present but the technique shape drifted' do
        report = JSON.parse(File.read(fixture))
        # Injection present, but its per-technique list is gone (renamed/re-nested upstream).
        report['data'][1]['value'][0]['data'] = []
        File.write(report_path, JSON.generate(report))
        expect { parser.parse }.to raise_error(described_class::MalformedReport, /injection point\(s\) present but no findings/)
      end
    end
  end
end
