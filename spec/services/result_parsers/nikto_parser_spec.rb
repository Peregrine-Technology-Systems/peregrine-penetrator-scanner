require 'sequel_helper'

RSpec.describe ResultParsers::NiktoParser do
  def parse(data)
    tmpfile = Tempfile.new(['nikto', '.json'])
    tmpfile.write(data.to_json)
    tmpfile.close
    described_class.new(tmpfile.path).parse
  ensure
    tmpfile.unlink
  end

  def ids(finding, type)
    (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
  end

  describe '#parse' do
    let(:nikto_data) do
      { 'vulnerabilities' => [
        { 'id' => '999990', 'OSVDB' => '0', 'method' => 'GET', 'url' => 'https://example.com/',
          'msg' => 'Server leaks version via X-Powered-By header' },
        { 'id' => '999991', 'OSVDB' => '877', 'method' => 'GET', 'url' => 'https://example.com/admin/',
          'msg' => 'Directory listing enabled on /admin/' },
        { 'id' => '999992', 'OSVDB' => '3092', 'method' => 'GET', 'url' => 'https://example.com/cgi-bin/test.cgi',
          'msg' => 'Remote code execution via test.cgi CVE-2021-12345' },
        { 'id' => '999993', 'OSVDB' => '0', 'method' => 'GET', 'url' => 'https://example.com/search',
          'msg' => 'Reflected XSS in search parameter' },
        { 'id' => '999994', 'OSVDB' => '0', 'method' => 'GET', 'url' => 'https://example.com/',
          'msg' => 'Outdated Apache version detected' }
      ] }
    end

    it 'parses vulnerabilities into contract misconfiguration findings' do
      results = parse(nikto_data)
      expect(results.length).to eq(5)
      expect(results).to all(include('source_tool' => 'nikto', 'probe' => 'server-misconfig',
                                     'finding_type' => 'misconfiguration'))
    end

    it 'maps message keywords to severity' do
      results = parse(nikto_data)
      sev = ->(frag) { results.find { |r| r['title']&.include?(frag) }['severity'] }
      expect(sev.call('Remote code execution')).to eq('critical')
      expect(sev.call('XSS')).to eq('high')
      expect(sev.call('Directory listing')).to eq('medium')
      expect(sev.call('Outdated')).to eq('low')
      expect(sev.call('header')).to eq('low')
    end

    it 'puts the url in a web location and the nikto id in tool_check_id' do
      first = parse(nikto_data).first
      expect(first.dig('location', 'url')).to eq('https://example.com/')
      expect(first['tool_check_id']).to eq('999990')
    end

    it 'extracts CVE IDs from messages into identifiers' do
      results = parse(nikto_data)
      rce = results.find { |r| r['title']&.include?('Remote code execution') }
      expect(ids(rce, 'cve')).to eq(['CVE-2021-12345'])
      no_cve = results.find { |r| r['title']&.include?('header') }
      expect(ids(no_cve, 'cve')).to be_empty
    end

    it 'includes evidence with method' do
      expect(parse(nikto_data).first['evidence']['method']).to eq('GET')
    end

    it 'handles host-based nikto output format' do
      results = parse('host' => [{ 'vulnerabilities' => [
                        { 'msg' => 'Test finding', 'id' => '1', 'url' => 'https://example.com' }
                      ] }])
      expect(results.length).to eq(1)
      expect(results.first['title']).to eq('Test finding')
    end

    it 'returns empty array for missing file' do
      expect(described_class.new('/nonexistent/file.json').parse).to eq([])
    end

    it 'returns empty array for invalid JSON' do
      tmpfile = Tempfile.new(['invalid', '.json'])
      tmpfile.write('not valid json')
      tmpfile.close
      expect(described_class.new(tmpfile.path).parse).to eq([])
    ensure
      tmpfile.unlink
    end
  end

  # #823: a genuine critical must not silently drop to `info` when upstream
  # rewords a message past the keyword heuristic. Severity is driven from a stable
  # identifier (test id / OSVDB id) via the maintained lookup; keyword inference
  # is only the unmapped fallback, and every fall-through to `info` is logged.
  describe 'severity from stable key (#823)' do
    def parse_one(vuln)
      parse('vulnerabilities' => [vuln]).first
    end

    it 'keeps a known-critical at critical even when the message would infer info' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => { '999992' => 'critical' }, 'by_osvdb' => {}
      )
      result = parse_one('id' => '999992', 'OSVDB' => '0', 'url' => 'https://example.com/cgi',
                         'msg' => 'Endpoint permits arbitrary OS operations')
      expect(result['severity']).to eq('critical')
    end

    it 'resolves severity by OSVDB id when the test id is unmapped' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => {}, 'by_osvdb' => { '12345' => 'high' }
      )
      result = parse_one('id' => '0', 'OSVDB' => '12345', 'url' => 'https://example.com/x',
                         'msg' => 'Something the keywords do not recognise')
      expect(result['severity']).to eq('high')
    end

    it 'never maps on OSVDB "0" (no OSVDB assigned)' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => {}, 'by_osvdb' => { '0' => 'critical' }
      )
      result = parse_one('id' => '7', 'OSVDB' => '0', 'url' => 'https://example.com/x',
                         'msg' => 'Unrecognised finding text')
      expect(result['severity']).to eq('info')
    end

    it 'logs (does not silently bucket) a finding that falls through to info' do
      allow(described_class).to receive(:severity_map).and_return(described_class::EMPTY_MAP)
      expect(Penetrator.logger).to receive(:warn).with(/Unmapped finding fell through to info/)
      parse_one('id' => '42', 'OSVDB' => '0', 'url' => 'https://example.com/x',
                'msg' => 'Some unrecognised observation')
    end

    it 'falls back to keyword inference when the finding is unmapped' do
      allow(described_class).to receive(:severity_map).and_return(described_class::EMPTY_MAP)
      result = parse_one('id' => '999992', 'OSVDB' => '0', 'url' => 'https://example.com/cgi',
                         'msg' => 'Remote code execution via test.cgi')
      expect(result['severity']).to eq('critical')
    end
  end

  describe '.load_severity_map' do
    it 'degrades to the empty map (keyword fallback) on malformed YAML' do
      allow(File).to receive(:exist?).with(described_class::SEVERITY_MAP_PATH).and_return(true)
      allow(YAML).to receive(:safe_load_file).with(described_class::SEVERITY_MAP_PATH)
                                             .and_raise(Psych::SyntaxError.new('f', 1, 1, 0, 'bad', 'ctx'))
      allow(Penetrator.logger).to receive(:error)
      expect(described_class.load_severity_map).to eq(described_class::EMPTY_MAP)
    end

    it 'returns the empty map when the file is absent' do
      allow(File).to receive(:exist?).with(described_class::SEVERITY_MAP_PATH).and_return(false)
      expect(described_class.load_severity_map).to eq(described_class::EMPTY_MAP)
    end
  end
end
