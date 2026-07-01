require 'sequel_helper'

RSpec.describe SmokeChecker do
  let(:target) { create(:target) }
  let(:scan) { create(:scan, target:, profile: 'smoke') }
  let(:checker) { described_class.new(scan) }

  describe '#run' do
    before do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload)
    end

    it 'returns a summary hash' do
      summary = checker.run

      expect(summary).to include('smoke_test' => true, 'total_findings' => 0)
      expect(summary['checks']).to be_a(Hash)
    end

    it 'checks tool availability' do
      checker.run

      expect(checker.results[:tools]).to include(status: match(/pass|fail/))
    end

    it 'checks secrets' do
      checker.run

      expect(checker.results[:secrets]).to include(status: match(/pass|fail/))
    end

    it 'checks GCS connectivity' do
      checker.run

      expect(checker.results[:gcs][:status]).to eq('pass')
    end

    it 'reports GCS failure when upload fails' do
      allow(StorageService).to receive(:new).and_raise(StandardError, 'No credentials')

      checker.run

      expect(checker.results[:gcs][:status]).to eq('fail')
    end
  end

  describe '#required_tools (drift-proof, derived from SCANNER_MAP)' do
    it 'covers the executable of every wired probe — all nine, correct binaries' do
      expect(checker.required_tools).to contain_exactly(
        'zap', 'nuclei', 'sqlmap', 'ffuf', 'nikto', 'testssl.sh', 'retire', 'trufflehog', 'amass'
      )
    end

    it 'reports each wired scanner as a class exposing its executable' do
      ScanOrchestrator::SCANNER_MAP.each_value do |klass|
        expect(klass.executable).to be_a(String).and(be_present)
      end
    end
  end

  describe '#check_tools' do
    before do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload)
    end

    it 'passes when every probe tool is present on PATH' do
      allow(checker).to receive(:tool_available?).and_return(true)
      checker.send(:check_tools)
      expect(checker.results[:tools]).to include(status: 'pass')
      expect(checker.results[:tools][:detail]).to include('present on PATH')
    end

    it 'fails and names the missing tool (e.g. a present-but-misnamed binary)' do
      allow(checker).to receive(:tool_available?) { |t| t != 'amass' }
      checker.send(:check_tools)
      expect(checker.results[:tools]).to include(status: 'fail')
      expect(checker.results[:tools][:detail]).to include('amass')
    end
  end

  describe '#passed?' do
    before do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload)
    end

    it 'returns true when all checks pass' do
      allow(checker).to receive(:tool_available?).and_return(true)
      stub_const('ENV', ENV.to_h.merge('GCS_BUCKET' => 'test', 'GOOGLE_CLOUD_PROJECT' => 'test'))

      checker.run

      expect(checker.passed?).to be true
    end

    it 'returns false when a check fails' do
      allow(StorageService).to receive(:new).and_raise(StandardError, 'fail')

      checker.run

      expect(checker.passed?).to be false
    end
  end
end
