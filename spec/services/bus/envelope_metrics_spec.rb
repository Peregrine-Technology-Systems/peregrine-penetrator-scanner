# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::EnvelopeMetrics do
  subject(:metrics) { described_class.new(consumer: 'penetrator-scanner') }

  it 'counts v1 and v2 opens separately, from the library hook names' do
    metrics.call('envelope_v1_opened')
    metrics.call('envelope_v2_opened')
    metrics.call('envelope_v2_opened')

    expect(metrics.count('v1')).to eq(1)
    expect(metrics.count('v2')).to eq(2)
  end

  it 'reports both series, including a zero, so "no v1 left" is a measurement not an absence' do
    metrics.call('envelope_v2_opened')

    expect(metrics.to_prometheus).to eq(<<~PROM)
      # TYPE peregrine_bus_envelope_opened_total counter
      peregrine_bus_envelope_opened_total{version="v1",consumer="penetrator-scanner"} 0
      peregrine_bus_envelope_opened_total{version="v2",consumer="penetrator-scanner"} 1
    PROM
  end

  it 'ignores library events that are not open counters, without raising' do
    expect { metrics.call('pointer_subject_mismatch') }.not_to raise_error
    expect(metrics.count('v1') + metrics.count('v2')).to eq(0)
  end

  it 'is driven by the real library: publish then consume counts one v2 open' do
    counter = described_class.new
    subject_name = Bus::ScanSubjects.requested
    substrate = Peregrine::Bus::MemorySubstrate.new
    adapter = Peregrine::Bus::Adapter.new(
      substrate:, transport: Peregrine::Bus::MemoryTransport.new, key_provider: keyset_for(subject_name),
      account: Bus::GrammarEnv.account, organization_id: BusHelper::ORGANIZATION, metrics: counter
    )
    Bus::Publisher.new(adapter).publish(subject_name, { 'job_id' => 'j1' })

    consume_plain(adapter, subject_name)

    expect([counter.count('v1'), counter.count('v2')]).to eq([0, 1])
  end

  it 'is safe under concurrent calls' do
    Array.new(8) { Thread.new { 200.times { metrics.call('envelope_v2_opened') } } }.each(&:join)

    expect(metrics.count('v2')).to eq(1600)
  end
end
