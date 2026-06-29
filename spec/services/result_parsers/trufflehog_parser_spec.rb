require 'sequel_helper'

RSpec.describe ResultParsers::TrufflehogParser do
  # Real trufflehog --json output captured against a generated RSA key (test
  # material, deleted after capture). NDJSON: one JSON object per line.
  let(:fixture) { Penetrator.root.join('spec/fixtures/trufflehog_results.json') }

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture, 'https://example.com').parse }

    it 'produces one contract secret finding per detected secret (1 in fixture)' do
      expect(findings.length).to eq(1)
      expect(findings).to all(include('source_tool' => 'trufflehog', 'probe' => 'secrets',
                                      'finding_type' => 'secret', 'severity' => 'high'))
    end

    it 'uses DetectorName as title and tool_check_id' do
      finding = findings.first
      expect(finding['title']).to include('Private')
      expect(finding['tool_check_id']).to be_present
    end

    it 'records the verified flag at the top level' do
      expect(findings.first['verified']).to be(true).or be(false)
    end

    it 'locates the secret in a file location' do
      expect(findings.first['location']).to include('kind' => 'file')
      expect(findings.first.dig('location', 'path')).to be_present
    end

    it 'stores only the Redacted field (never the full Raw secret)' do
      ev = findings.first['evidence']
      expect(ev).to have_key('redacted')
      expect(ev.keys).not_to include('raw')
    end
  end

  describe '#parse error handling' do
    it 'returns [] for a missing file' do
      expect(described_class.new('/nonexistent.json', 'https://x.com').parse).to eq([])
    end

    it 'returns [] for an empty file (no secrets)' do
      tmp = Tempfile.new(['empty', '.json'])
      tmp.write('')
      tmp.close
      expect(described_class.new(tmp.path, 'https://x.com').parse).to eq([])
    ensure
      tmp.unlink
    end

    it 'skips malformed lines and parses the rest' do
      tmp = Tempfile.new(['mixed', '.json'])
      good = '{"SourceMetadata":{"Data":{"Filesystem":{"file":"/f.js","line":1}}},' \
             '"DetectorName":"TestDetector","DetectorDescription":"Test","Verified":false,' \
             '"Redacted":"abc***","ExtraData":{}}'
      tmp.write("not-json\n#{good}\n")
      tmp.close
      findings = described_class.new(tmp.path, 'https://x.com').parse
      expect(findings.length).to eq(1)
      expect(findings.first.dig('location', 'path')).to eq('/f.js')
    ensure
      tmp.unlink
    end
  end
end
