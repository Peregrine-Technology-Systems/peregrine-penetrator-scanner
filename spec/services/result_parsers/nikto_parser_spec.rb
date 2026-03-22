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
end
