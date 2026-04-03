require 'sequel_helper'

RSpec.describe ControlPlaneLoop do
  let(:loop_instance) do
    described_class.new(
      scan_uuid: 'scan-123',
      job_id: 'job-456',
      callback_url: 'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
      gcs_bucket: 'test-bucket',
      callback_secret: 'secret'
    )
  end

  before do
    # Prevent actual HTTP calls and GCS writes
    allow_any_instance_of(HeartbeatSender).to receive(:send_heartbeat) # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(StorageService).to receive(:upload_json) # rubocop:disable RSpec/AnyInstance
  end

  describe '#start / #stop' do
    it 'starts a background thread' do
      loop_instance.start
      expect(loop_instance.instance_variable_get(:@thread)).to be_alive
      loop_instance.stop
    end

    it 'stops the background thread' do
      loop_instance.start
      loop_instance.stop
      thread = loop_instance.instance_variable_get(:@thread)
      expect(thread).not_to be_alive
    end
  end

  describe '#cancelled?' do
    it 'returns false initially' do
      expect(loop_instance.cancelled?).to be false
    end

    it 'is thread-safe' do
      threads = 10.times.map do
        Thread.new { loop_instance.cancelled? }
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe '#update_progress' do
    it 'updates the progress data for heartbeats' do
      loop_instance.update_progress(current_tool: 'nuclei', progress_pct: 50, findings_count: 8)
      progress = loop_instance.instance_variable_get(:@progress)
      expect(progress[:current_tool]).to eq('nuclei')
    end
  end

  describe 'tick behavior' do
    it 'calls heartbeat sender on tick' do
      sender = instance_double(HeartbeatSender)
      allow(HeartbeatSender).to receive(:new).and_return(sender)
      expect(sender).to receive(:send_heartbeat).with(hash_including(status: 'running'))

      loop_instance.send(:tick)
    end

    it 'writes GCS heartbeat on tick' do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      expect(storage).to receive(:upload_json).with(
        'control/scan-123/heartbeat.json',
        hash_including(scan_uuid: 'scan-123', status: 'running', timestamp: anything)
      )

      loop_instance.send(:tick)
    end

    it 'skips GCS heartbeat when no bucket configured' do
      no_bucket_loop = described_class.new(
        scan_uuid: 'scan-123',
        job_id: 'job-456',
        callback_url: 'https://reporter.example.com/callbacks/scan_complete',
        gcs_bucket: '',
        callback_secret: 'secret'
      )

      expect_any_instance_of(StorageService).not_to receive(:upload_json) # rubocop:disable RSpec/AnyInstance
      no_bucket_loop.send(:tick)
    end

    it 'includes progress data in GCS heartbeat' do
      loop_instance.update_progress(current_tool: 'zap', findings_count: 5)

      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      expect(storage).to receive(:upload_json).with(
        anything,
        hash_including(current_tool: 'zap', findings_count: 5)
      )

      loop_instance.send(:tick)
    end
  end
end
