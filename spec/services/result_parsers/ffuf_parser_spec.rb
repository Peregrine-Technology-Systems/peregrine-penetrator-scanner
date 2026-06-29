require 'sequel_helper'

RSpec.describe ResultParsers::FfufParser do
  describe '#parse' do
    let(:ffuf_data) do
      { 'results' => [
        { 'input' => { 'FUZZ' => 'admin' }, 'url' => 'https://example.com/admin', 'status' => 200,
          'length' => 4523, 'words' => 234, 'lines' => 56, 'content-type' => 'text/html' },
        { 'input' => { 'FUZZ' => 'secret' }, 'url' => 'https://example.com/secret', 'status' => 403,
          'length' => 162, 'content-type' => 'text/html' },
        { 'input' => { 'FUZZ' => 'old-page' }, 'url' => 'https://example.com/old-page', 'status' => 301,
          'length' => 0, 'content-type' => 'text/html', 'redirectlocation' => 'https://example.com/new-page' }
      ] }
    end

    def parse(data)
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(data.to_json)
      tmpfile.close
      described_class.new(tmpfile.path).parse
    ensure
      tmpfile.unlink
    end

    it 'parses results into contract exposure findings' do
      results = parse(ffuf_data)
      expect(results.length).to eq(3)
      expect(results).to all(include('source_tool' => 'ffuf', 'probe' => 'content-discovery',
                                     'finding_type' => 'exposure'))
    end

    it 'maps status codes to severity (403 → low, else info)' do
      results = parse(ffuf_data)
      by_url = results.to_h { |r| [r.dig('location', 'url'), r['severity']] }
      expect(by_url['https://example.com/admin']).to eq('info')
      expect(by_url['https://example.com/secret']).to eq('low')
      expect(by_url['https://example.com/old-page']).to eq('info')
    end

    it 'puts the discovered URL in a web location and the endpoint in the title' do
      first = parse(ffuf_data).first
      expect(first.dig('location', 'url')).to eq('https://example.com/admin')
      expect(first['title']).to include('admin')
    end

    it 'includes response details in evidence' do
      results = parse(ffuf_data)
      expect(results.first['evidence']).to include('status_code' => 200, 'content_length' => 4523,
                                                   'content_type' => 'text/html')
      redirect = results.find { |r| r.dig('location', 'url') == 'https://example.com/old-page' }
      expect(redirect['evidence']['redirect_location']).to eq('https://example.com/new-page')
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

    it 'handles empty results array' do
      expect(parse('results' => [])).to eq([])
    end
  end
end
