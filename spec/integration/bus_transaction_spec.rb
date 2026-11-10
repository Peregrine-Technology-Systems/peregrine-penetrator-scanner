# frozen_string_literal: true

require 'sequel_helper'
require 'support/bus_helper'
require 'support/nats_server_helper'
require 'peregrine/bus/nats'
require 'nats/client'

# scanner#1276 (arch#1319): the scanner's bus transaction, tested in CI before merge.
#
# A real `nats-server -js` carries a sealed scan.requested to the REAL Bus::WorkerLoop,
# which consumes it, runs the job, and publishes the sealed terminal event back over the
# same server. A missing nats-server FAILS this spec (never skips): a green run that did
# not exercise NATS is a silent-OK.
#
# Stated gaps, per the arch#1319 ruling (the interim in-process form; the shared GCS
# stand-in follows when peregrine-bus#170 ships):
# - the baked unit (scanner-worker.service), .bake/run.sh and bin/scan are not run here;
# - the substrate is an in-process MemorySubstrate, not GCS (AdapterEnv.substrate is GCS-only);
# - ScanJobRunner is replaced, so scanners and report export are not exercised.
# The keyset is generated per run by BusHelper#keyset_for; no static key exists in the worker.
RSpec.describe 'Scanner bus transaction', :bus_transaction do # rubocop:disable RSpec/DescribeClass
  include BusHelper
  include NatsServerHelper

  let(:requested) { Bus::ScanSubjects.requested }
  let(:completed) { Bus::ScanSubjects.terminal('completed') }
  let(:failed) { Bus::ScanSubjects.terminal('failed') }
  let(:keyset) { keyset_for(requested, completed, failed) }
  let(:substrate) { Peregrine::Bus::MemorySubstrate.new }
  let(:js) { NATS.connect(nats_url).jetstream }
  let(:transport) { Peregrine::Bus::Nats::NatsTransport.new(client: js) }
  let(:adapter) { adapter_for(transport) }

  def adapter_for(transport)
    Peregrine::Bus::Adapter.new(substrate:, transport:, key_provider: keyset,
                                account: Bus::GrammarEnv.account, organization_id: BusHelper::ORGANIZATION)
  end

  def publish_request(adapter, body)
    adapter.publish(requested, JSON.generate(body), job_id: body[:job_id], status: 'requested')
  end

  def read_terminal(adapter, subject)
    adapter.consume(subject, expected_organization_id: Peregrine::Bus::ANY_ORGANIZATION)
           .map { |opened| JSON.parse(opened.plaintext) }
  end

  around do |example|
    with_nats_server { example.run }
  end

  before do
    provision_stream_and_durables(js, transport, [requested, completed, failed])
    allow(Penetrator.logger).to receive(:error)
  end

  def run_worker
    Bus::WorkerLoop.new(consumer: Bus::ScanRequestConsumer.new(adapter:), publisher: Bus::Publisher.new(adapter),
                        drain_idle_seconds: 1, poll_interval: 0.05).run
  end

  it 'consumes a sealed scan.requested over NATS and runs the job with its payload' do
    runner = instance_double(ScanJobRunner, call: nil)
    allow(ScanJobRunner).to receive(:new).and_return(runner)

    publish_request(adapter, job_id: 'job-1', transaction_id: 'txn-1', environment: 'test',
                             target_url: 'https://scanme.example/', profile: 'quick')
    run_worker

    expect(ScanJobRunner).to have_received(:new).with(profile: 'quick', target_name: 'scanme.example',
                                                      target_urls: ['https://scanme.example/'])
    expect(runner).to have_received(:call).once
  end

  it 'answers a request with no target_url with a sealed scan.failed (refusal is a completion event)' do
    publish_request(adapter, job_id: 'job-2', transaction_id: 'txn-2', environment: 'test')
    run_worker

    events = read_terminal(adapter, failed)
    expect(events.map { |e| e['job_id'] }).to eq(['job-2'])
    expect(events.first).to include('state' => 'failed', 'reason' => 'invalid_request', 'transaction_id' => 'txn-2')
  end

  it 'acks the request: a second worker pass finds nothing to run' do
    allow(ScanJobRunner).to receive(:new).and_return(instance_double(ScanJobRunner, call: nil))
    publish_request(adapter, job_id: 'job-3', transaction_id: 'txn-3', environment: 'test',
                             target_url: 'https://scanme.example/')
    run_worker
    run_worker

    expect(ScanJobRunner).to have_received(:new).once
  end
end
