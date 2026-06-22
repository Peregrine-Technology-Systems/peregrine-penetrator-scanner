require 'sequel_helper'

RSpec.describe ResultParsers::AmassParser do
  # Real amass v5 `amass subs` text output format: "Session Scope" header,
  # then "FQDN:" section with one hostname per line. Domain names are returned
  # as discovered_urls (prepended with https://). amass returns discovered hosts,
  # not vulnerability findings, so the return key is :discovered_urls. See #47.
  let(:fixture) { Penetrator.root.join('spec/fixtures/amass_results.txt') }

  describe '#parse (against real-format fixture)' do
    subject(:result) { described_class.new(fixture).parse }

    it 'returns a hash with discovered_urls key' do
      expect(result).to be_a(Hash)
      expect(result).to have_key(:discovered_urls)
    end

    it 'parses 4 hostnames from the fixture' do
      expect(result[:discovered_urls].length).to eq(4)
    end

    it 'prepends https:// to each hostname' do
      expect(result[:discovered_urls]).to all(start_with('https://'))
    end

    it 'includes a specific expected host' do
      expect(result[:discovered_urls]).to include('https://api.auxscan.app.data-estate.cloud')
    end

    it 'skips the Session Scope header line' do
      urls = result[:discovered_urls]
      expect(urls).not_to include(a_string_including('Session'))
    end

    it 'skips the FQDN: label line' do
      urls = result[:discovered_urls]
      expect(urls).not_to include(a_string_including('FQDN'))
    end
  end

  describe '#parse error handling' do
    it 'returns empty discovered_urls for a missing file' do
      result = described_class.new('/nonexistent.txt').parse
      expect(result[:discovered_urls]).to eq([])
    end

    it 'returns empty discovered_urls when no hostnames found' do
      tmp = Tempfile.new(['empty', '.txt'])
      tmp.write("Session Scope\n\nFQDN:\n\n")
      tmp.close
      result = described_class.new(tmp.path).parse
      expect(result[:discovered_urls]).to eq([])
    ensure
      tmp.unlink
    end
  end
end
