require 'rails_helper'

RSpec.describe ResultParsers::SqlmapParser do
  describe '#parse' do
    let(:output_dir) { Penetrator.root.join('tmp/test_sqlmap_output') }
    let(:url) { 'https://example.com/page?id=1' }
    let(:parser) { described_class.new(output_dir, url) }

    let(:sqlmap_log_content) do
      <<~LOG
        [INFO] testing connection to the target URL
        [INFO] testing 'AND boolean-based blind - WHERE or HAVING clause'
        Parameter: id (GET)
            Type: boolean-based blind
            Title: AND boolean-based blind - WHERE or HAVING clause
            Payload: id=1 AND 5678=5678

        Parameter: name (POST)
            Type: time-based blind
            Title: MySQL >= 5.0.12 time-based blind
            Payload: name=test' AND SLEEP(5)-- -
      LOG
    end

    before do
      FileUtils.mkdir_p(output_dir.join('example.com'))
      File.write(output_dir.join('example.com', 'log'), sqlmap_log_content)
    end

    after do
      FileUtils.rm_rf(output_dir)
    end

    it 'parses injection points from sqlmap log' do
      results = parser.parse
      expect(results.length).to eq(2)
    end

    it 'sets source_tool to sqlmap' do
      results = parser.parse
      results.each { |r| expect(r[:source_tool]).to eq('sqlmap') }
    end

    it 'sets severity to high' do
      results = parser.parse
      results.each { |r| expect(r[:severity]).to eq('high') }
    end

    it 'extracts parameter name' do
      results = parser.parse
      params = results.pluck(:parameter)
      expect(params).to include('id')
      expect(params).to include('name')
    end

    it 'includes injection type in title' do
      results = parser.parse
      titles = results.pluck(:title)
      expect(titles).to include('SQL Injection - GET')
      expect(titles).to include('SQL Injection - POST')
    end

    it 'sets CWE-89 for SQL injection' do
      results = parser.parse
      results.each { |r| expect(r[:cwe_id]).to eq('CWE-89') }
    end

    it 'includes URL in results' do
      results = parser.parse
      results.each { |r| expect(r[:url]).to eq(url) }
    end

    it 'includes evidence with injection details' do
      results = parser.parse
      results.each do |r|
        expect(r[:evidence]).to be_a(Hash)
        expect(r[:evidence][:injection_type]).to be_present
        expect(r[:evidence][:url]).to eq(url)
      end
    end

    it 'includes log context in evidence' do
      results = parser.parse
      expect(results.first[:evidence][:log_excerpt]).to be_present
    end

    it 'returns empty array when output dir does not exist' do
      parser = described_class.new(Pathname.new('/nonexistent/path'), url)
      expect(parser.parse).to eq([])
    end

    it 'returns empty array when no log file found' do
      empty_dir = Penetrator.root.join('tmp/test_sqlmap_empty')
      FileUtils.mkdir_p(empty_dir)

      parser = described_class.new(empty_dir, url)
      expect(parser.parse).to eq([])
    ensure
      FileUtils.rm_rf(empty_dir)
    end

    it 'returns empty array when log has no injection points' do
      no_injections = "sqlmap identified the following injection point(s):\n[INFO] testing done\n"
      File.write(output_dir.join('example.com', 'log'), no_injections)

      expect(parser.parse).to eq([])
    end
  end
end
