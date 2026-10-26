# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::WorkerLoop do
  let(:consumer) { instance_double(Bus::ScanRequestConsumer) }
  let(:publisher) { instance_double(Bus::Publisher, publish: nil) }
  let(:times) { [] }
  let(:clock) { -> { times.shift } }
  let(:job_runner) { instance_double(ScanJobRunner, call: nil) }

  def worker(drain_idle_seconds: 10)
    described_class.new(consumer:, publisher:, drain_idle_seconds:, poll_interval: 0, clock:)
  end

  before do
    allow(InstanceMetadata).to receive(:tp_id).and_return('tp-1')
    allow(ScanJobRunner).to receive(:new).and_return(job_runner)
  end

  describe '#run' do
    it 'runs a job for each pulled request, then idle-exits once the drain timeout elapses' do
      bus_request = { 'job_id' => 'j1', 'profile' => 'standard', 'target_url' => 'https://example.com' }
      allow(consumer).to receive(:next_request).and_return(bus_request, nil)
      times.push(0, 5, 8, 20) # boot, post-job reset, idle-check(not yet), idle-check(timed out)

      worker.run

      expect(job_runner).to have_received(:call)
    end

    it 'publishes exiting on the SAME heartbeat subject as ControlPlaneLoop, never a separate .exiting. subject' do
      allow(consumer).to receive(:next_request).and_return(nil)
      times.push(0, 100) # boot, idle-check immediately timed out

      worker.run

      expect(publisher).to have_received(:publish).with(
        'peregrine.telemetry.tp.scanner.heartbeat.tp-1',
        hash_including(tp_id: 'tp-1', state: 'exiting', reason: 'idle_timeout'),
        status: 'exiting'
      )
    end

    it 'reports reason: sigterm when exiting was triggered by drain!, not an idle timeout' do
      allow(consumer).to receive(:next_request)
      times.push(0)
      w = worker
      w.drain!

      w.run

      expect(publisher).to have_received(:publish).with(
        anything, hash_including(reason: 'sigterm'), anything
      )
    end

    it 'skips the exiting publish when tp_id is absent (off-bus)' do
      allow(InstanceMetadata).to receive(:tp_id).and_return('')
      allow(consumer).to receive(:next_request).and_return(nil)
      times.push(0, 100)

      worker.run

      expect(publisher).not_to have_received(:publish)
    end

    it 'drain! stops the loop before its next pull, without waiting on an idle timeout' do
      allow(consumer).to receive(:next_request)
      times.push(0)
      w = worker
      w.drain!

      w.run

      expect(consumer).not_to have_received(:next_request)
    end

    it 'refuses a request with no target_url instead of scanning localhost (#1235)' do
      bus_request = { 'job_id' => 'j1', 'transaction_id' => 't1', 'environment' => 'staging', 'profile' => 'standard' }
      allow(consumer).to receive(:next_request).and_return(bus_request, nil)
      allow(Penetrator.logger).to receive(:error)
      times.push(0, 5, 8, 20)

      worker.run

      expect(ScanJobRunner).not_to have_received(:new)
      expect(Penetrator.logger).to have_received(:error).with(/invalid scan\.requested for job "j1".*target_url/)
      expect(publisher).to have_received(:publish).with(
        Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'failed'),
        hash_including(job_id: 'j1', transaction_id: 't1', environment: 'staging',
                       state: 'failed', reason: 'invalid_request'),
        job_id: 'j1', status: 'failed'
      )
    end

    it 'also refuses a request whose target_url is only whitespace (#1241)' do
      allow(consumer).to receive(:next_request).and_return({ 'job_id' => 'j1', 'target_url' => "  \n" }, nil)
      allow(Penetrator.logger).to receive(:error)
      times.push(0, 5, 8, 20)

      worker.run

      expect(ScanJobRunner).not_to have_received(:new)
    end

    it 'still runs a request that has a target_url' do
      bus_request = { 'job_id' => 'j1', 'target_url' => 'https://example.com' }
      allow(consumer).to receive(:next_request).and_return(bus_request, nil)
      times.push(0, 5, 8, 20)

      worker.run

      expect(ScanJobRunner).to have_received(:new).with(hash_including(target_urls: ['https://example.com']))
    end

    it 'sets and clears the per-job ENV identity around a raising job, without the exception escaping' do
      allow(job_runner).to receive(:call).and_raise(StandardError, 'boom')
      bus_request = { 'job_id' => 'j1', 'transaction_id' => 't1', 'environment' => 'staging' }
      allow(consumer).to receive(:next_request).and_return(bus_request, nil)
      times.push(0, 5, 8, 20)

      expect { worker.run }.not_to raise_error
      expect(ENV.fetch('SCAN_UUID', nil)).to be_nil
      expect(ENV.fetch('TRANSACTION_ID', nil)).to be_nil
    end
  end

  describe '.default_drain_idle_seconds' do
    around do |example|
      original = ENV.to_h.slice('SCANNER_DRAIN_IDLE_SECONDS', 'TP_DRAIN_IDLE_SECONDS')
      example.run
      ENV['SCANNER_DRAIN_IDLE_SECONDS'] = original['SCANNER_DRAIN_IDLE_SECONDS']
      ENV['TP_DRAIN_IDLE_SECONDS'] = original['TP_DRAIN_IDLE_SECONDS']
    end

    it 'falls back to 480 when neither override is set' do
      ENV.delete('SCANNER_DRAIN_IDLE_SECONDS')
      ENV.delete('TP_DRAIN_IDLE_SECONDS')

      expect(described_class.default_drain_idle_seconds).to eq(480)
    end

    it 'prefers the shared fleet-wide TP_DRAIN_IDLE_SECONDS over the default' do
      ENV.delete('SCANNER_DRAIN_IDLE_SECONDS')
      ENV['TP_DRAIN_IDLE_SECONDS'] = '600'

      expect(described_class.default_drain_idle_seconds).to eq(600)
    end

    it 'prefers the per-class SCANNER_DRAIN_IDLE_SECONDS over the shared fleet-wide one' do
      ENV['SCANNER_DRAIN_IDLE_SECONDS'] = '90'
      ENV['TP_DRAIN_IDLE_SECONDS'] = '600'

      expect(described_class.default_drain_idle_seconds).to eq(90)
    end
  end
end
