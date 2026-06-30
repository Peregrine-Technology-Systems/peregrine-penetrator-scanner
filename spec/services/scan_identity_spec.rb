# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe ScanIdentity do
  # Snapshot + restore the env keys from_env reads, so examples are isolated.
  around do |example|
    keys = %w[SCAN_UUID TRANSACTION_ID ENVIRONMENT TRACE_ID]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    keys.each { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before { allow(InstanceMetadata).to receive(:tp_id).and_return('txn-scanner-xyz') }

  describe '.from_env' do
    it 'gathers the full bus envelope when every field is injected' do
      ENV['SCAN_UUID'] = 'scan-uuid-1'
      ENV['TRANSACTION_ID'] = 'txn-1'
      ENV['ENVIRONMENT'] = 'production'
      ENV['TRACE_ID'] = 'trace-1'

      id = described_class.from_env(scan_id: 'ignored-when-uuid-present')

      expect(id.scan_uuid).to eq('scan-uuid-1')
      expect(id.transaction_id).to eq('txn-1')
      expect(id.environment).to eq('production')
      expect(id.trace_id).to eq('trace-1')
      expect(id.tp_id).to eq('txn-scanner-xyz')
    end

    it 'falls back to the scan record id when SCAN_UUID is unset' do
      expect(described_class.from_env(scan_id: 42).scan_uuid).to eq('42')
    end

    it 'falls back to Penetrator.env when ENVIRONMENT is unset' do
      expect(described_class.from_env(scan_id: 1).environment).to eq(Penetrator.env)
    end

    it 'leaves transaction_id and trace_id nil when not injected (pre-launcher / off-bus)' do
      id = described_class.from_env(scan_id: 1)
      expect(id.transaction_id).to be_nil
      expect(id.trace_id).to be_nil
    end

    it 'treats a blank env value as unset' do
      ENV['TRANSACTION_ID'] = ''
      expect(described_class.from_env(scan_id: 1).transaction_id).to be_nil
    end
  end

  describe '#to_h' do
    it 'compacts nil fields so absent identity adds no empty keys' do
      id = described_class.new(scan_uuid: 's', transaction_id: nil, environment: 'test', trace_id: nil, tp_id: 'tp')
      expect(id.to_h).to eq(scan_uuid: 's', environment: 'test', tp_id: 'tp')
    end

    it 'carries every field when all are present' do
      id = described_class.new(scan_uuid: 's', transaction_id: 't', environment: 'e', trace_id: 'r', tp_id: 'p')
      expect(id.to_h).to eq(scan_uuid: 's', transaction_id: 't', environment: 'e', trace_id: 'r', tp_id: 'p')
    end
  end

  describe '#in_flight' do
    it 'is empty when there is no transaction_id' do
      id = described_class.new(scan_uuid: 's', transaction_id: nil, environment: 'e', trace_id: nil, tp_id: 'p')
      expect(id.in_flight).to eq([])
    end

    it 'lists the transaction_id when present (heartbeat value, not key)' do
      id = described_class.new(scan_uuid: 's', transaction_id: 't', environment: 'e', trace_id: nil, tp_id: 'p')
      expect(id.in_flight).to eq(['t'])
    end
  end
end
