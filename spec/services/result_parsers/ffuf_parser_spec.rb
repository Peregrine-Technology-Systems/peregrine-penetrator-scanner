require 'sequel_helper'

RSpec.describe ResultParsers::FfufParser do
  describe '#parse' do
    let(:ffuf_data) do
      {
        'results' => [
          {
            'input' => { 'FUZZ' => 'admin' },
            'url' => 'https://example.com/admin',
            'status' => 200,
            'length' => 4523,
            'words' => 234,
            'lines' => 56,
            'content-type' => 'text/html',
            'redirectlocation' => nil
          },
          {
            'input' => { 'FUZZ' => 'secret' },
            'url' => 'https://example.com/secret',
            'status' => 403,
            'length' => 162,
            'words' => 6,
            'lines' => 8,
            'content-type' => 'text/html',
            'redirectlocation' => nil
          },
          {
            'input' => { 'FUZZ' => 'old-page' },
            'url' => 'https://example.com/old-page',
            'status' => 301,
            'length' => 0,
            'words' => 0,
            'lines' => 0,
            'content-type' => 'text/html',
            'redirectlocation' => 'https://example.com/new-page'
          }
        ]
      }
    end

    it 'parses all results from ffuf output' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.length).to eq(3)
    ensure
      tmpfile.unlink
    end

    it 'sets source_tool to ffuf' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      results.each { |r| expect(r[:source_tool]).to eq('ffuf') }
    ensure
      tmpfile.unlink
    end

    it 'maps 200 status to info severity' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      admin_finding = results.find { |r| r[:url] == 'https://example.com/admin' }
      expect(admin_finding[:severity]).to eq('info')
    ensure
      tmpfile.unlink
    end

    it 'maps 403 status to low severity' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      secret_finding = results.find { |r| r[:url] == 'https://example.com/secret' }
      expect(secret_finding[:severity]).to eq('low')
    ensure
      tmpfile.unlink
    end

    it 'maps 301/302 status to info severity' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      redirect_finding = results.find { |r| r[:url] == 'https://example.com/old-page' }
      expect(redirect_finding[:severity]).to eq('info')
    ensure
      tmpfile.unlink
    end

    it 'includes title with discovered endpoint' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      expect(results.first[:title]).to include('admin')
    ensure
      tmpfile.unlink
    end

    it 'includes evidence with response details' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      evidence = results.first[:evidence]
      expect(evidence[:status_code]).to eq(200)
      expect(evidence[:content_length]).to eq(4523)
      expect(evidence[:content_type]).to eq('text/html')
    ensure
      tmpfile.unlink
    end

    it 'includes redirect location in evidence when present' do
      tmpfile = Tempfile.new(['ffuf', '.json'])
      tmpfile.write(ffuf_data.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      results = parser.parse

      redirect = results.find { |r| r[:url] == 'https://example.com/old-page' }
      expect(redirect[:evidence][:redirect_location]).to eq('https://example.com/new-page')
    ensure
      tmpfile.unlink
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

    it 'handles empty results array' do
      tmpfile = Tempfile.new(['empty', '.json'])
      tmpfile.write({ 'results' => [] }.to_json)
      tmpfile.close

      parser = described_class.new(tmpfile.path)
      expect(parser.parse).to eq([])
    ensure
      tmpfile.unlink
    end
  end
end
