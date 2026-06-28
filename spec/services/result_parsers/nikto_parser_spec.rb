require 'sequel_helper'

RSpec.describe ResultParsers::NiktoParser do
  describe '#parse' do
    let(:nikto_data) do
      {
        'vulnerabilities' => [
          {
            'id' => '999990',
            'OSVDB' => '0',
            'method' => 'GET',
            'url' => 'https://example.com/',
            'msg' => 'Server leaks version via X-Powered-By header'
          },
          {
            'id' => '999991',
            'OSVDB' => '877',
            'method' => 'GET',
            'url' => 'https://example.com/admin/',
            'msg' => 'Directory listing enabled on /admin/'
          },
          {
            'id' => '999992',
            'OSVDB' => '3092',
            'method' => 'GET',
            'url' => 'https://example.com/cgi-bin/test.cgi',
            'msg' => 'Remote code execution via test.cgi CVE-2021-12345'
          },
          {
            'id' => '999993',
            'OSVDB' => '0',
            'method' => 'GET',
            'url' => 'https://example.com/search',
            'msg' => 'Reflected XSS in search parameter'
          },
          {
            'id' => '999994',
            'OSVDB' => '0',
            'method' => 'GET',
            'url' => 'https://example.com/',
            'msg' => 'Outdated Apache version detected'
          }
        ]
      }
    end

    it 'parses all vulnerabilities' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.length).to eq(5)
    ensure
      tmpfile.unlink
    end

    it 'sets source_tool to nikto' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      results.each { |r| expect(r[:source_tool]).to eq('nikto') }
    ensure
      tmpfile.unlink
    end

    it 'maps RCE-related messages to critical severity' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      rce = results.find { |r| r[:title]&.include?('Remote code execution') }
      expect(rce[:severity]).to eq('critical')
    ensure
      tmpfile.unlink
    end

    it 'maps XSS-related messages to high severity' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      xss = results.find { |r| r[:title]&.include?('XSS') }
      expect(xss[:severity]).to eq('high')
    ensure
      tmpfile.unlink
    end

    it 'maps directory listing to medium severity' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      dir_listing = results.find { |r| r[:title]&.include?('Directory listing') }
      expect(dir_listing[:severity]).to eq('medium')
    ensure
      tmpfile.unlink
    end

    it 'maps outdated software to low severity' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      outdated = results.find { |r| r[:title]&.include?('Outdated') }
      expect(outdated[:severity]).to eq('low')
    ensure
      tmpfile.unlink
    end

    it 'maps header-related messages to low severity' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      header = results.find { |r| r[:title]&.include?('header') }
      expect(header[:severity]).to eq('low')
    ensure
      tmpfile.unlink
    end

    it 'extracts CVE IDs from messages' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      rce = results.find { |r| r[:title]&.include?('Remote code execution') }
      expect(rce[:cve_id]).to eq('CVE-2021-12345')
    ensure
      tmpfile.unlink
    end

    it 'sets cve_id to nil when no CVE in message' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      no_cve = results.find { |r| r[:title]&.include?('header') }
      expect(no_cve[:cve_id]).to be_nil
    ensure
      tmpfile.unlink
    end

    it 'includes evidence with OSVDB and method' do
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write(nikto_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.first[:evidence][:method]).to eq('GET')
    ensure
      tmpfile.unlink
    end

    it 'handles host-based nikto output format' do
      results = parse_host_format_data
      expect(results.length).to eq(1)
      expect(results.first[:title]).to eq('Test finding')
    end

    it 'returns empty array for missing file' do
      parser = described_class.new('/nonexistent/file.json')
      expect(parser.parse).to eq([])
    end

    it 'returns empty array for invalid JSON' do
      tmpfile = Tempfile.new(['invalid', '.json'])
      tmpfile.write('not valid json')
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      expect(parser.parse).to eq([])
    ensure
      tmpfile.unlink
    end

    def parse_host_format_data
      host_format = {
        'host' => [{
          'vulnerabilities' => [
            { 'msg' => 'Test finding', 'id' => '1', 'url' => 'https://example.com' }
          ]
        }]
      }

      tmpfile = Tempfile.new(['nikto_host', '.json'])
      tmpfile.write(host_format.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      parser.parse
    ensure
      tmpfile&.unlink
    end
  end

  # #823: a genuine critical must not silently drop to `info` when upstream
  # reword a message past the keyword heuristic. Severity is driven from a stable
  # identifier (test id / OSVDB id) via the maintained lookup; keyword inference
  # is only the unmapped fallback, and every fall-through to `info` is logged.
  describe 'severity from stable key (#823)' do
    def parse_one(vuln)
      tmpfile = Tempfile.new(['nikto', '.json'])
      tmpfile.write({ 'vulnerabilities' => [vuln] }.to_json)
      tmpfile.close
      described_class.new(tmpfile.path).parse.first
    ensure
      tmpfile.unlink
    end

    it 'keeps a known-critical at critical even when the message would infer info' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => { '999992' => 'critical' }, 'by_osvdb' => {}
      )

      # Reworded message the keyword heuristic would bucket as info ("arbitrary
      # OS operations" matches none of the critical/high/medium/low keywords).
      result = parse_one(
        'id' => '999992', 'OSVDB' => '0', 'url' => 'https://example.com/cgi',
        'msg' => 'Endpoint permits arbitrary OS operations'
      )

      expect(result[:severity]).to eq('critical')
    end

    it 'resolves severity by OSVDB id when the test id is unmapped' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => {}, 'by_osvdb' => { '12345' => 'high' }
      )

      result = parse_one(
        'id' => '0', 'OSVDB' => '12345', 'url' => 'https://example.com/x',
        'msg' => 'Something the keywords do not recognise'
      )

      expect(result[:severity]).to eq('high')
    end

    it 'never maps on OSVDB "0" (no OSVDB assigned)' do
      allow(described_class).to receive(:severity_map).and_return(
        'by_id' => {}, 'by_osvdb' => { '0' => 'critical' }
      )

      result = parse_one(
        'id' => '7', 'OSVDB' => '0', 'url' => 'https://example.com/x',
        'msg' => 'Unrecognised finding text'
      )

      expect(result[:severity]).to eq('info')
    end

    it 'logs (does not silently bucket) a finding that falls through to info' do
      allow(described_class).to receive(:severity_map).and_return(described_class::EMPTY_MAP)
      expect(Penetrator.logger).to receive(:warn).with(/Unmapped finding fell through to info/)

      parse_one(
        'id' => '42', 'OSVDB' => '0', 'url' => 'https://example.com/x',
        'msg' => 'Some unrecognised observation'
      )
    end

    it 'falls back to keyword inference when the finding is unmapped' do
      allow(described_class).to receive(:severity_map).and_return(described_class::EMPTY_MAP)

      result = parse_one(
        'id' => '999992', 'OSVDB' => '0', 'url' => 'https://example.com/cgi',
        'msg' => 'Remote code execution via test.cgi'
      )

      expect(result[:severity]).to eq('critical')
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
