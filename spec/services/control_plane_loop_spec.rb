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
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload_json)

      instance = described_class.new(
        scan_uuid: 'scan-123', job_id: 'job-456',
        callback_url: 'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
        gcs_bucket: 'test-bucket', callback_secret: 'secret'
      )
      instance.update_progress(current_tool: 'zap', findings_count: 5)

      expect(storage).to receive(:upload_json).with(
        anything,
        hash_including(current_tool: 'zap', findings_count: 5)
      )

      instance.send(:tick)
    end

    it 'enriches the GCS heartbeat with bus-envelope identity when provided' do
      storage = instance_double(StorageService)
      allow(StorageService).to receive(:new).and_return(storage)

      identity = ScanIdentity.new(scan_uuid: 'scan-123', transaction_id: 'txn-1',
                                  environment: 'production', trace_id: 'trace-1', tp_id: 'tp-9')
      instance = described_class.new(
        scan_uuid: 'scan-123', job_id: 'job-456', callback_url: '',
        gcs_bucket: 'test-bucket', callback_secret: 'secret', identity:
      )

      expect(storage).to receive(:upload_json).with(
        'control/scan-123/heartbeat.json',
        hash_including(transaction_id: 'txn-1', environment: 'production', trace_id: 'trace-1', tp_id: 'tp-9')
      )

      instance.send(:tick)
    end

    it 'publishes a telemetry-plane heartbeat keyed by tp-id, carrying in_flight txn ids' do
      identity = ScanIdentity.new(scan_uuid: 'scan-123', transaction_id: 'txn-1',
                                  environment: 'production', trace_id: nil, tp_id: 'tp-9')
      subj = Peregrine::Bus::Subjects::Penetrator.scanner_heartbeat('tp-9')
      publisher, adapter = bus_pair(subj)
      allow(StorageService).to receive(:new).and_return(instance_double(StorageService, upload_json: nil))

      instance = described_class.new(
        scan_uuid: 'scan-123', job_id: 'job-456', callback_url: '',
        gcs_bucket: 'test-bucket', callback_secret: 'secret', identity:, publisher:
      )
      instance.update_progress(current_tool: 'nuclei', findings_count: 2)
      instance.send(:tick)

      msg = JSON.parse(adapter.consume(subj).first)
      expect(msg['tp_id']).to eq('tp-9')
      expect(msg['in_flight']).to eq(['txn-1'])
      expect(msg['current_tool']).to eq('nuclei')
    end

    it 'skips the bus heartbeat when identity has no tp_id (off-bus)' do
      publisher = instance_double(Bus::Publisher)
      allow(publisher).to receive(:publish)
      allow(StorageService).to receive(:new).and_return(instance_double(StorageService, upload_json: nil))
      instance = described_class.new(
        scan_uuid: 'scan-123', job_id: 'j', callback_url: '',
        gcs_bucket: 'test-bucket', callback_secret: 's',
        identity: ScanIdentity.new(scan_uuid: 'scan-123', transaction_id: nil, environment: 'test', trace_id: nil, tp_id: ''),
        publisher:
      )

      instance.send(:tick)

      expect(publisher).not_to have_received(:publish)
    end
  end

  describe '#run_loop' do
    it 'ticks, then keeps ticking until stopped' do
      allow(loop_instance).to receive(:tick)
      allow(loop_instance).to receive(:sleep) { loop_instance.instance_variable_set(:@running, false) }
      loop_instance.instance_variable_set(:@running, true)

      loop_instance.send(:run_loop)

      expect(loop_instance).to have_received(:tick).at_least(:once)
    end

    it 'logs and exits if the loop body crashes' do
      allow(loop_instance).to receive(:sleep)
      allow(loop_instance).to receive(:tick).and_raise('crash')
      allow(Penetrator.logger).to receive(:error)
      loop_instance.instance_variable_set(:@running, true)

      loop_instance.send(:run_loop)

      expect(Penetrator.logger).to have_received(:error).with(/Loop crashed: crash/)
    end
  end

  describe '#safe_call' do
    it 'logs and swallows a timeout' do
      allow(Penetrator.logger).to receive(:warn)
      loop_instance.send(:safe_call, 'thing') { raise Timeout::Error }
      expect(Penetrator.logger).to have_received(:warn).with(/thing timed out/)
    end

    it 'logs and swallows a StandardError' do
      allow(Penetrator.logger).to receive(:warn)
      loop_instance.send(:safe_call, 'thing') { raise 'boom' }
      expect(Penetrator.logger).to have_received(:warn).with(/thing error: boom/)
    end
  end

  describe '#check_cancel' do
    it 'flips cancelled? when the flag reader reports a cancel' do
      allow(ControlFlagReader).to receive_messages(
        enabled?: true, new: instance_double(ControlFlagReader, cancelled?: true)
      )

      loop_instance.send(:check_cancel)

      expect(loop_instance.cancelled?).to be(true)
    end
  end
end
