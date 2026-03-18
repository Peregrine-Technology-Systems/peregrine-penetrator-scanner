require 'rails_helper'

RSpec.describe ResultParsers::DawnParser do
  describe '#parse' do
    let(:dawn_data) do
      {
        'vulnerabilities' => [
          {
            'name' => 'CVE-2021-22885',
            'severity' => 'High',
            'cwe' => 'CWE-200',
            'cve' => 'CVE-2021-22885',
            'description' => 'Information disclosure in Action Pack',
            'remediation' => 'Upgrade to Rails >= 6.1.3.2',
            'gem_name' => 'actionpack',
            'gem_version' => '6.1.0'
          },
          {
            'name' => 'CVE-2021-22904',
            'severity' => 'Medium',
            'cwe' => 'CWE-400',
            'cve' => 'CVE-2021-22904',
            'description' => 'Denial of Service in Action Controller',
            'remediation' => 'Upgrade to Rails >= 6.1.3.2',
            'gem_name' => 'actionpack',
            'gem_version' => '6.1.0'
          },
          {
            'name' => 'Insecure dependency',
            'severity' => 'Critical',
            'cwe' => nil,
            'cve' => nil,
            'description' => 'Critical vulnerability found',
            'remediation' => 'Update gem'
          },
          {
            'name' => 'Minor issue',
            'severity' => 'unknown_severity',
            'cwe' => nil,
            'cve' => nil,
            'description' => 'Unknown severity test'
          }
        ]
      }
    end

    it 'parses all vulnerabilities' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.length).to eq(4)
    ensure
      tmpfile.unlink
    end

    it 'sets source_tool to dawn' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      results.each { |r| expect(r[:source_tool]).to eq('dawn') }
    ensure
      tmpfile.unlink
    end

    it 'maps severity correctly (case-insensitive)' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results[0][:severity]).to eq('high')
      expect(results[1][:severity]).to eq('medium')
      expect(results[2][:severity]).to eq('critical')
    ensure
      tmpfile.unlink
    end

    it 'defaults to medium for unknown severity' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      unknown = results.find { |r| r[:title] == 'Minor issue' }
      expect(unknown[:severity]).to eq('medium')
    ensure
      tmpfile.unlink
    end

    it 'extracts CWE and CVE IDs' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      first = results.first
      expect(first[:cwe_id]).to eq('CWE-200')
      expect(first[:cve_id]).to eq('CVE-2021-22885')
    ensure
      tmpfile.unlink
    end

    it 'sets url to nil (dawn scans source code, not URLs)' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      results.each { |r| expect(r[:url]).to be_nil }
    ensure
      tmpfile.unlink
    end

    it 'includes gem info in evidence' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      first = results.first
      expect(first[:evidence][:affected_gem]).to eq('actionpack')
      expect(first[:evidence][:affected_version]).to eq('6.1.0')
      expect(first[:evidence][:description]).to be_present
      expect(first[:evidence][:remediation]).to be_present
    ensure
      tmpfile.unlink
    end

    it 'compacts nil evidence values' do
      tmpfile = Tempfile.new(['dawn', '.json'])
      tmpfile.write(dawn_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      # The last entry has no gem_name/gem_version
      last = results.last
      expect(last[:evidence]).not_to have_key(:affected_gem)
      expect(last[:evidence]).not_to have_key(:affected_version)
    ensure
      tmpfile.unlink
    end

    it 'returns empty array for missing file' do
      parser = described_class.new('/nonexistent/file.json')
      expect(parser.parse).to eq([])
    end

    it 'returns empty array for invalid JSON' do
      tmpfile = Tempfile.new(['invalid', '.json'])
      tmpfile.write('not valid json {{{')
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      expect(parser.parse).to eq([])
    ensure
      tmpfile.unlink
    end

    it 'handles empty vulnerabilities array' do
      tmpfile = Tempfile.new(['empty', '.json'])
      tmpfile.write({ 'vulnerabilities' => [] }.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      expect(parser.parse).to eq([])
    ensure
      tmpfile.unlink
    end
  end
end
