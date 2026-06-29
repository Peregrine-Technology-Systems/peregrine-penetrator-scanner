require 'sequel_helper'

RSpec.describe ResultParsers::ZapParser do
  subject(:parser) { described_class.new(fixture_path) }

  let(:fixture_path) { Penetrator.root.join('spec/fixtures/zap_results.json').to_s }

  def ids(finding, type)
    (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
  end

  describe '#parse' do
    it 'returns contract findings' do
      results = parser.parse
      expect(results).to be_an(Array).and(be_present)
      expect(results).to all(include('source_tool' => 'zap', 'probe' => 'web-dast',
                                     'finding_type' => 'vulnerability'))
    end

    it 'parses all instances from all alerts' do
      # 1 instance from first alert + 2 instances from second alert = 3
      expect(parser.parse.length).to eq(3)
    end

    it 'maps ZAP risk codes to severity levels' do
      results = parser.parse
      expect(results.find { |f| f['title'] == 'X-Content-Type-Options Header Missing' }['severity']).to eq('low')
      expect(results.find { |f| f['title'] == 'Cross Site Scripting (Reflected)' }['severity']).to eq('high')
    end

    it 'puts each instance URL + parameter in a web location' do
      results = parser.parse
      urls = results.map { |f| f.dig('location', 'url') }
      expect(urls).to include('https://example.com/api/users', 'https://example.com/search?q=test')
      xss = results.find { |f| f.dig('location', 'url') == 'https://example.com/search?q=test' }
      expect(xss['location']['parameter']).to eq('q')
    end

    it 'formats CWE IDs with the CWE- prefix in identifiers' do
      xss = parser.parse.find { |f| f['title'] == 'Cross Site Scripting (Reflected)' }
      expect(ids(xss, 'cwe')).to include('CWE-79')
    end

    it 'carries the alert description and the pluginid as tool_check_id' do
      finding = parser.parse.first
      expect(finding['description']).to be_present
      expect(finding).to have_key('tool_check_id')
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

    it 'handles alerts with no instances gracefully' do
      tmpfile = Tempfile.new(['empty_alerts', '.json'])
      tmpfile.write({ 'site' => [{ 'alerts' => [{ 'name' => 'Test', 'riskcode' => '1', 'instances' => [] }] }] }.to_json)
      tmpfile.close
      expect(described_class.new(tmpfile.path).parse).to eq([])
    ensure
      tmpfile.unlink
    end
  end
end
