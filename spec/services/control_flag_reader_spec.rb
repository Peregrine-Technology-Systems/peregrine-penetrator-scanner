require 'sequel_helper'

RSpec.describe ControlFlagReader do
  let(:reader) { described_class.new(gcs_bucket: 'test-bucket', scan_uuid: 'scan-123') }

  # Use stub classes to avoid loading real GCS library (conflicts with storage_service_spec mocks)
  let(:mock_storage) { double('storage') }
  let(:mock_bucket) { double('bucket') }

  before do
    allow(reader).to receive(:bucket).and_return(mock_bucket)
  end

  describe '#cancelled?' do
    it 'returns true when control.json has action: cancel' do
      mock_file = double('file')
      allow(mock_bucket).to receive(:file).and_return(mock_file)
      allow(mock_file).to receive(:download).and_return(StringIO.new('{"action":"cancel","reason":"stale_heartbeat"}'))

      expect(reader.cancelled?).to be true
    end

    it 'returns false when control.json does not exist' do
      allow(mock_bucket).to receive(:file).and_return(nil)

      expect(reader.cancelled?).to be false
    end

    it 'returns false when action is not cancel' do
      mock_file = double('file')
      allow(mock_bucket).to receive(:file).and_return(mock_file)
      allow(mock_file).to receive(:download).and_return(StringIO.new('{"action":"pause"}'))

      expect(reader.cancelled?).to be false
    end

    it 'returns false on GCS error' do
      allow(reader).to receive(:bucket).and_raise(StandardError, 'GCS unavailable')

      expect(reader.cancelled?).to be false
    end

    it 'returns false on JSON parse error' do
      mock_file = double('file')
      allow(mock_bucket).to receive(:file).and_return(mock_file)
      allow(mock_file).to receive(:download).and_return(StringIO.new('not json'))

      expect(reader.cancelled?).to be false
    end
  end

  describe '.enabled?' do
    it 'returns true when GCS_BUCKET and GOOGLE_CLOUD_PROJECT are set' do
      stub_const('ENV', ENV.to_h.merge('GCS_BUCKET' => 'bucket', 'GOOGLE_CLOUD_PROJECT' => 'project'))
      expect(described_class.enabled?).to be true
    end

    it 'returns false when GCS_BUCKET is not set' do
      stub_const('ENV', ENV.to_h.except('GCS_BUCKET'))
      expect(described_class.enabled?).to be false
    end
  end
end
