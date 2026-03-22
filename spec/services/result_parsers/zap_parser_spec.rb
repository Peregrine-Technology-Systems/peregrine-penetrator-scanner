require 'sequel_helper'

RSpec.describe ResultParsers::ZapParser do
  subject(:parser) { described_class.new(fixture_path) }

  let(:fixture_path) { Penetrator.root.join('spec/fixtures/zap_results.json').to_s }

  describe '#parse' do
    it 'returns an array of finding hashes' do
      results = parser.parse

      expect(results).to be_an(Array)
      expect(results).not_to be_empty
    end

    it 'parses all instances from all alerts' do
      results = parser.parse

      # 1 instance from first alert + 2 instances from second alert = 3
      expect(results.length).to eq(3)
    end

    it 'sets source_tool to zap' do
      results = parser.parse

      results.each do |finding|
        expect(finding[:source_tool]).to eq('zap')
      end
    end

    it 'maps ZAP risk codes to severity levels' do
      results = parser.parse

      low_findings = results.select { |f| f[:title] == 'X-Content-Type-Options Header Missing' }
      expect(low_findings.first[:severity]).to eq('low')

      high_findings = results.select { |f| f[:title] == 'Cross Site Scripting (Reflected)' }
      expect(high_findings.first[:severity]).to eq('high')
    end

    it 'extracts the URL from each instance' do
      results = parser.parse

      urls = results.pluck(:url)
      expect(urls).to include('https://example.com/api/users')
      expect(urls).to include('https://example.com/search?q=test')
    end

    it 'extracts the parameter from instances' do
      results = parser.parse

      xss_finding = results.find { |f| f[:url] == 'https://example.com/search?q=test' }
      expect(xss_finding[:parameter]).to eq('q')
    end

    it 'formats CWE IDs with the CWE- prefix' do
      results = parser.parse

      xss_finding = results.find { |f| f[:title] == 'Cross Site Scripting (Reflected)' }
      expect(xss_finding[:cwe_id]).to eq('CWE-79')
    end

    it 'includes evidence with description and solution' do
      results = parser.parse

      finding = results.first
      expect(finding[:evidence]).to be_a(Hash)
      expect(finding[:evidence][:description]).to be_present
    end

    it 'returns empty array for missing file' do
      parser = described_class.new('/nonexistent/file.json')
      results = parser.parse

      expect(results).to eq([])
    end

    it 'returns empty array for invalid JSON' do
      tmpfile = Tempfile.new(['invalid', '.json'])
      tmpfile.write('not valid json')
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results).to eq([])
    ensure
      tmpfile.unlink
    end

    it 'handles alerts with no instances gracefully' do
      tmpfile = Tempfile.new(['empty_alerts', '.json'])
      tmpfile.write({ 'site' => [{ 'alerts' => [{ 'name' => 'Test', 'riskcode' => '1', 'instances' => [] }] }] }.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results).to eq([])
    ensure
      tmpfile.unlink
    end
  end
end
