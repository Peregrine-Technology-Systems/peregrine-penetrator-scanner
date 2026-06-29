require 'sequel_helper'

RSpec.describe ResultParsers::SqlmapParser do
  describe '#parse' do
    let(:output_dir) { Penetrator.root.join('tmp/test_sqlmap_output') }
    let(:url) { 'https://example.com/page?id=1' }
    let(:parser) { described_class.new(output_dir, url) }

    let(:sqlmap_log_content) do
      <<~LOG
        [INFO] testing connection to the target URL
        Parameter: id (GET)
            Type: boolean-based blind
            Payload: id=1 AND 5678=5678

        Parameter: name (POST)
            Type: time-based blind
            Payload: name=test' AND SLEEP(5)-- -
      LOG
    end

    before do
      FileUtils.mkdir_p(output_dir.join('example.com'))
      File.write(output_dir.join('example.com', 'log'), sqlmap_log_content)
    end

    after { FileUtils.rm_rf(output_dir) }

    def ids(finding, type)
      (finding['identifiers'] || []).select { |i| i['type'] == type }.map { |i| i['value'] }
    end

    it 'parses injection points into contract findings' do
      results = parser.parse
      expect(results.length).to eq(2)
      expect(results).to all(include('source_tool' => 'sqlmap', 'probe' => 'injection',
                                     'finding_type' => 'vulnerability', 'severity' => 'high'))
    end

    it 'puts the parameter + url in a web location' do
      results = parser.parse
      expect(results.map { |r| r.dig('location', 'parameter') }).to include('id', 'name')
      expect(results).to all(satisfy { |r| r.dig('location', 'url') == url })
    end

    it 'titles the finding by injection place' do
      titles = parser.parse.map { |r| r['title'] }
      expect(titles).to include('SQL Injection - GET', 'SQL Injection - POST')
    end

    it 'tags CWE-89 in identifiers' do
      expect(parser.parse).to all(satisfy { |r| ids(r, 'cwe') == ['CWE-89'] })
    end

    it 'includes evidence with injection details + log context' do
      finding = parser.parse.first
      expect(finding['evidence']['injection_type']).to be_present
      expect(finding['evidence']['log_excerpt']).to be_present
    end

    it 'returns empty array when output dir does not exist' do
      expect(described_class.new(Pathname.new('/nonexistent/path'), url).parse).to eq([])
    end

    it 'returns empty array when no log file found' do
      empty_dir = Penetrator.root.join('tmp/test_sqlmap_empty')
      FileUtils.mkdir_p(empty_dir)
      expect(described_class.new(empty_dir, url).parse).to eq([])
    ensure
      FileUtils.rm_rf(empty_dir)
    end

    it 'returns empty array when log has no injection points' do
      File.write(output_dir.join('example.com', 'log'), "[INFO] testing done\n")
      expect(parser.parse).to eq([])
    end
  end
end
