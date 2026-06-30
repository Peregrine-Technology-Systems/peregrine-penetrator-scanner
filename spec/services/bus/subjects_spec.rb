# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::Subjects do
  describe '.scan_terminal' do
    it 'maps completed/success to the data-plane completion subject' do
      expect(described_class.scan_terminal('completed')).to eq('data.task.penetrator.scan.completed')
      expect(described_class.scan_terminal('success')).to eq('data.task.penetrator.scan.completed')
    end

    it 'maps failed/upload_failed to the data-plane failure subject' do
      expect(described_class.scan_terminal('failed')).to eq('data.task.penetrator.scan.failed')
      expect(described_class.scan_terminal('upload_failed')).to eq('data.task.penetrator.scan.failed')
    end

    it 'accepts symbols' do
      expect(described_class.scan_terminal(:completed)).to eq('data.task.penetrator.scan.completed')
    end

    it 'raises on an unknown terminal state' do
      expect { described_class.scan_terminal('running') }.to raise_error(ArgumentError, /unknown scan terminal state/)
    end
  end

  describe '.scan_heartbeat' do
    it 'keys the telemetry-plane subject by tp-id alone' do
      expect(described_class.scan_heartbeat('txn-scanner-abc')).to eq('telemetry.tp.scanner.heartbeat.txn-scanner-abc')
    end

    it 'raises when tp_id is blank (would produce a keyless liveness subject)' do
      expect { described_class.scan_heartbeat('') }.to raise_error(ArgumentError, /tp_id required/)
      expect { described_class.scan_heartbeat(nil) }.to raise_error(ArgumentError, /tp_id required/)
    end
  end
end
