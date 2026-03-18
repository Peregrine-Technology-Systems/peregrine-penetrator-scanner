require 'rails_helper'

RSpec.describe ResultParsers::NucleiParser do
  subject(:parser) { described_class.new(fixture_path) }

  let(:fixture_path) { Rails.root.join('spec/fixtures/nuclei_results.jsonl').to_s }

  describe '#parse' do
    it 'returns an array of finding hashes' do
      results = parser.parse

      expect(results).to be_an(Array)
      expect(results).not_to be_empty
    end

    it 'parses all JSONL lines' do
      results = parser.parse

      expect(results.length).to eq(3)
    end

    it 'sets source_tool to nuclei' do
      results = parser.parse

      results.each do |finding|
        expect(finding[:source_tool]).to eq('nuclei')
      end
    end

    it 'maps Nuclei severity levels correctly' do
      results = parser.parse

      critical_finding = results.find { |f| f[:title] == 'Log4j RCE (CVE-2021-44228)' }
      expect(critical_finding[:severity]).to eq('critical')

      high_finding = results.find { |f| f[:title] == 'Confluence Authentication Bypass' }
      expect(high_finding[:severity]).to eq('high')

      info_finding = results.find { |f| f[:title] == 'Technology Detection' }
      expect(info_finding[:severity]).to eq('info')
    end

    it 'extracts matched-at URL' do
      results = parser.parse

      log4j = results.find { |f| f[:title] =~ /Log4j/ }
      expect(log4j[:url]).to eq('https://example.com/api/login')
    end

    it 'extracts CVE IDs from classification' do
      results = parser.parse

      log4j = results.find { |f| f[:title] =~ /Log4j/ }
      expect(log4j[:cve_id]).to eq('CVE-2021-44228')
    end

    it 'extracts CWE IDs from classification' do
      results = parser.parse

      log4j = results.find { |f| f[:title] =~ /Log4j/ }
      expect(log4j[:cwe_id]).to eq('CWE-502')
    end

    it 'includes evidence with template details' do
      results = parser.parse

      log4j = results.find { |f| f[:title] =~ /Log4j/ }
      expect(log4j[:evidence][:template_id]).to eq('cve-2021-44228-log4j-rce')
      expect(log4j[:evidence][:curl_command]).to be_present
    end

    it 'handles nil CVE and CWE gracefully' do
      results = parser.parse

      tech_detect = results.find { |f| f[:title] == 'Technology Detection' }
      expect(tech_detect[:cve_id]).to be_nil
      expect(tech_detect[:cwe_id]).to be_nil
    end

    it 'returns empty array for missing file' do
      parser = described_class.new('/nonexistent/file.jsonl')
      results = parser.parse

      expect(results).to eq([])
    end

    it 'skips invalid JSON lines and continues parsing' do
      tmpfile = Tempfile.new(['mixed', '.jsonl'])
      tmpfile.write("{\"template-id\":\"test\",\"info\":{\"name\":\"Valid\",\"severity\":\"high\"},\"matched-at\":\"https://example.com\"}\n")
      tmpfile.write("not valid json\n")
      tmpfile.write("{\"template-id\":\"test2\",\"info\":{\"name\":\"Also Valid\",\"severity\":\"low\"},\"matched-at\":\"https://example.com/2\"}\n")
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.length).to eq(2)
    ensure
      tmpfile.unlink
    end

    it 'skips empty lines' do
      tmpfile = Tempfile.new(['blank_lines', '.jsonl'])
      tmpfile.write("{\"template-id\":\"test\",\"info\":{\"name\":\"Valid\",\"severity\":\"high\"},\"matched-at\":\"https://example.com\"}\n")
      tmpfile.write("\n")
      tmpfile.write("   \n")
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.length).to eq(1)
    ensure
      tmpfile.unlink
    end
  end
end
