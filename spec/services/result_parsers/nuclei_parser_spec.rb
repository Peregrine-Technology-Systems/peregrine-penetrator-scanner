require 'sequel_helper'

RSpec.describe ResultParsers::NucleiParser do
  subject(:parser) { described_class.new(fixture_path) }

  let(:fixture_path) { Penetrator.root.join('spec/fixtures/nuclei_results.jsonl').to_s }

  def ids(finding, type)
    (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
  end

  describe '#parse' do
    it 'returns contract findings' do
      results = parser.parse
      expect(results).to be_an(Array).and(be_present)
      expect(results).to all(include('source_tool' => 'nuclei', 'probe' => 'template-cve',
                                     'finding_type' => 'vulnerability'))
    end

    it 'parses all JSONL lines' do
      expect(parser.parse.length).to eq(3)
    end

    it 'maps Nuclei severity levels correctly' do
      results = parser.parse
      expect(results.find { |f| f['title'] == 'Log4j RCE (CVE-2021-44228)' }['severity']).to eq('critical')
      expect(results.find { |f| f['title'] == 'Confluence Authentication Bypass' }['severity']).to eq('high')
      expect(results.find { |f| f['title'] == 'Technology Detection' }['severity']).to eq('info')
    end

    it 'puts the matched-at URL in a web location' do
      log4j = parser.parse.find { |f| f['title'] =~ /Log4j/ }
      expect(log4j['location']).to include('kind' => 'web', 'url' => 'https://example.com/api/login')
    end

    it 'records the template id as tool_check_id' do
      log4j = parser.parse.find { |f| f['title'] =~ /Log4j/ }
      expect(log4j['tool_check_id']).to eq('cve-2021-44228-log4j-rce')
    end

    it 'preserves CVE and CWE identifiers' do
      log4j = parser.parse.find { |f| f['title'] =~ /Log4j/ }
      expect(ids(log4j, 'cve')).to include('CVE-2021-44228')
      expect(ids(log4j, 'cwe')).to include('CWE-502')
    end

    it 'carries tool-reported scores' do
      results = parser.parse
      log4j = results.find { |f| f['title'] =~ /Log4j/ }
      expect(log4j['scores']).to include(
        'cvss_score' => 10.0,
        'cvss_vector' => 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H',
        'epss_score' => 0.97565
      )
      expect(results.find { |f| f['title'] =~ /Confluence/ }['scores']['cvss_score']).to eq(9.8)
    end

    it 'omits scores when the template has none' do
      tech = parser.parse.find { |f| f['title'] == 'Technology Detection' }
      expect(tech['scores']).to be_nil
    end

    it 'has no CVE/CWE identifiers when classification lacks them' do
      tech = parser.parse.find { |f| f['title'] == 'Technology Detection' }
      expect(ids(tech, 'cve')).to be_empty
      expect(ids(tech, 'cwe')).to be_empty
    end

    it 'includes evidence with template details' do
      log4j = parser.parse.find { |f| f['title'] =~ /Log4j/ }
      expect(log4j['evidence']['curl_command']).to be_present
    end

    it 'returns empty array for missing file' do
      expect(described_class.new('/nonexistent/file.jsonl').parse).to eq([])
    end

    it 'skips invalid JSON lines and continues parsing' do
      tmpfile = Tempfile.new(['mixed', '.jsonl'])
      tmpfile.write("{\"template-id\":\"t\",\"info\":{\"name\":\"Valid\",\"severity\":\"high\"},\"matched-at\":\"https://example.com\"}\n")
      tmpfile.write("not valid json\n")
      tmpfile.write("{\"template-id\":\"t2\",\"info\":{\"name\":\"Also Valid\",\"severity\":\"low\"},\"matched-at\":\"https://example.com/2\"}\n")
      tmpfile.close
      expect(described_class.new(tmpfile.path).parse.length).to eq(2)
    ensure
      tmpfile.unlink
    end

    it 'skips empty lines' do
      tmpfile = Tempfile.new(['blank_lines', '.jsonl'])
      tmpfile.write("{\"template-id\":\"t\",\"info\":{\"name\":\"Valid\",\"severity\":\"high\"},\"matched-at\":\"https://example.com\"}\n")
      tmpfile.write("\n   \n")
      tmpfile.close
      expect(described_class.new(tmpfile.path).parse.length).to eq(1)
    ensure
      tmpfile.unlink
    end
  end
end
