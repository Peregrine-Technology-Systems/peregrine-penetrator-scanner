require 'sequel_helper'

RSpec.describe ResultParsers::TrufflehogParser do
  # Real trufflehog --json output captured by running `trufflehog filesystem`
  # with --include-detectors=PrivateKey against a generated RSA key (test material,
  # key deleted after fixture capture). NDJSON format: one JSON object per line.
  let(:fixture) { Penetrator.root.join('spec/fixtures/trufflehog_results.json') }

  describe '#parse (against real fixture)' do
    subject(:findings) { described_class.new(fixture, 'https://example.com').parse }

    it 'produces one finding per detected secret (1 in fixture)' do
      expect(findings.length).to eq(1)
    end

    it 'tags every finding with source_tool trufflehog' do
      expect(findings.map { |f| f[:source_tool] }.uniq).to eq(['trufflehog'])
    end

    it 'uses DetectorName as title' do
      expect(findings.first[:title]).to include('PrivateKey').or include('Private')
    end

    it 'maps all findings to high severity (leaked secrets are always serious)' do
      expect(findings.map { |f| f[:severity] }.uniq).to eq(['high'])
    end

    it 'sets url to the target_url' do
      expect(findings.first[:url]).to eq('https://example.com')
    end

    it 'includes DetectorName and Verified in evidence' do
      ev = findings.first[:evidence]
      expect(ev).to have_key(:detector_name)
      expect(ev).to have_key(:verified)
    end

    it 'stores only the Redacted field from trufflehog (not the full Raw value)' do
      ev = findings.first[:evidence]
      # trufflehog's Redacted is a truncated form; Raw is the full secret body — must not be stored
      expect(ev.keys).not_to include(:raw)
      expect(ev).to have_key(:redacted)
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
    ensure
      tmp.unlink
    end
  end
end
