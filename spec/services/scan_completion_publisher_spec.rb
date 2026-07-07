# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe ScanCompletionPublisher do
  let(:scan) { create(:scan, :completed) }
  let(:exporter) do
    instance_double(ScanResultsExporter, claim_check: { bucket: 'reports-bkt', object: 'scan-results/t/s/scan_results.json', sha256: 'deadbeef' })
  end
  let(:identity) do
    ScanIdentity.new(scan_uuid: 's1', transaction_id: 'txn-1', environment: 'production', trace_id: 'trace-1', tp_id: 'tp-1')
  end

  it 'emits scan.completed with a claim-check pointer that round-trips through the adapter' do
    subj = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'completed')
    publisher, adapter = bus_pair(subj)

    described_class.new(scan, exporter:, identity:, publisher:).emit

    msg = JSON.parse(adapter.consume(subj).first)
    expect(msg['state']).to eq('completed')
    expect(msg['schema_version']).to eq('2.1')
    expect(msg['scanner_result_uri']).to eq('bucket' => 'reports-bkt', 'object' => 'scan-results/t/s/scan_results.json', 'sha256' => 'deadbeef')
    expect(msg).to include('transaction_id' => 'txn-1', 'tp_id' => 'tp-1', 'scan_uuid' => 's1')
    expect(msg['completed_at']).to be_present
  end

  it 'maps a failed scan onto the scan.failed subject' do
    failed = create(:scan, :running).tap { |s| s.status = 'failed' }
    subj = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed')
    publisher, adapter = bus_pair(subj)

    described_class.new(failed, exporter:, identity:, publisher:).emit

    expect(adapter.consume(subj).length).to eq(1)
  end

  it 'maps a cancelled scan onto the scan.failed subject (saga treats it as failure)' do
    cancelled = create(:scan, :running).tap { |s| s.status = 'cancelled' }
    subj = Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed')
    publisher, adapter = bus_pair(subj)

    described_class.new(cancelled, exporter:, identity:, publisher:).emit

    expect(adapter.consume(subj).length).to eq(1)
  end

  it 'no-ops when the publisher is disabled (GCS status.json is the durable fallback)' do
    result = described_class.new(scan, exporter:, identity:, publisher: Bus::Publisher.new(nil)).emit
    expect(result).to be_nil
  end
end
