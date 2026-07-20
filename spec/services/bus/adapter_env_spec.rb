# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles -- GCS/NATS classes can't be loaded (conflicts with storage_service_spec mocks)
require 'sequel_helper'
require 'tempfile'

# Stubs `require` itself (the StorageService/ControlFlagReader convention) rather
# than actually loading google-cloud-storage/pubsub or nats-pure — those are heavy
# real clients this unit test has no business booting, and a REAL require of
# "google/cloud/storage" here would permanently define the `Google::Cloud::Storage`
# constant for the rest of the suite, breaking storage_service_spec's `Class.new` +
# `stub_const` double pattern for every spec file loaded after this one.
RSpec.describe Bus::AdapterEnv do
  around do |example|
    saved = ENV.to_h.slice('BUS_BUCKET', 'BUS_KEYSET_PATH', 'BUS_TRANSPORT', 'BUS_T_MODE', 'NATS_URL', 'NATS_CREDS')
    example.run
  ensure
    saved.each { |k, v| ENV[k] = v }
    (%w[BUS_BUCKET BUS_KEYSET_PATH BUS_TRANSPORT BUS_T_MODE NATS_URL NATS_CREDS] - saved.keys).each { |k| ENV.delete(k) }
  end

  before do
    # peregrine/bus/{gcp,nats} are our own thin wrapper gems (GcsSubstrate,
    # PubSubTransport, NatsTransport) — load them for real, that's what's under
    # test. Only stub away the heavy third-party client libraries, whose classes
    # (Google::Cloud::Storage, Google::Cloud::PubSub, NATS) collide by name with
    # other specs' Class.new + stub_const doubles if ever really loaded.
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require).with(%r{\A(google/cloud/(storage|pubsub)|nats/client)\z}).and_return(true)
  end

  def stub_gcs_storage!
    gcs_class = Class.new { def bucket(*); end }
    stub_const('Google::Cloud::Storage', gcs_class)
    allow(gcs_class).to receive(:new).and_return(instance_double(gcs_class, bucket: double('bucket')))
  end

  def stub_nats_connect!
    nats_class = Class.new { def self.connect(*); end }
    stub_const('NATS', nats_class)
    allow(nats_class).to receive(:connect).and_return(double('nats connection', jetstream: double('jetstream context')))
    nats_class
  end

  def set_nats_env!(keyset_path, creds: '/dev/shm/peregrine/synadia.creds')
    ENV['BUS_BUCKET'] = 'bucket'
    ENV['BUS_KEYSET_PATH'] = keyset_path
    ENV['BUS_TRANSPORT'] = 'nats'
    ENV['NATS_URL'] = 'nats://example.invalid:4222'
    creds ? (ENV['NATS_CREDS'] = creds) : ENV.delete('NATS_CREDS')
  end

  describe '.adapter' do
    it 'returns nil until the production substrate ships (disabled by default, scanner#1009)' do
      expect(described_class.adapter).to be_nil
    end

    it 'returns nil when only BUS_BUCKET is set' do
      ENV['BUS_BUCKET'] = 'bucket'
      expect(described_class.adapter).to be_nil
    end

    it 'builds a real adapter once BUS_BUCKET + BUS_KEYSET_PATH are both present (pubsub default)' do
      Tempfile.create(['keyset', '.json']) do |f|
        f.write('{"current":{},"keys":{}}')
        f.flush
        ENV['BUS_BUCKET'] = 'bucket'
        ENV['BUS_KEYSET_PATH'] = f.path

        stub_gcs_storage!
        pubsub_class = Class.new
        stub_const('Google::Cloud::PubSub', pubsub_class)
        allow(pubsub_class).to receive(:new).and_return(instance_double(pubsub_class))

        adapter = described_class.adapter
        expect(adapter).to be_a(Peregrine::Bus::Adapter)
      end
    end

    it 'selects the NATS transport and passes user_credentials when BUS_TRANSPORT=nats + NATS_CREDS is set' do
      Tempfile.create(['keyset', '.json']) do |f|
        f.write('{"current":{},"keys":{}}')
        f.flush
        set_nats_env!(f.path)
        stub_gcs_storage!
        nats_class = stub_nats_connect!

        adapter = described_class.adapter

        expect(adapter).to be_a(Peregrine::Bus::Adapter)
        expect(nats_class).to have_received(:connect)
          .with('nats://example.invalid:4222', user_credentials: '/dev/shm/peregrine/synadia.creds')
      end
    end

    it 'degrades to no adapter (fail-soft) when BUS_TRANSPORT=nats but NATS_CREDS is unset' do
      Tempfile.create(['keyset', '.json']) do |f|
        f.write('{"current":{},"keys":{}}')
        f.flush
        set_nats_env!(f.path, creds: nil)
        stub_gcs_storage!
        nats_class = stub_nats_connect!

        expect(described_class.adapter).to be_nil
        expect(nats_class).not_to have_received(:connect)
      end
    end

    it 'is fail-soft — returns nil and logs a warning on construction error' do
      ENV['BUS_BUCKET'] = 'bucket'
      ENV['BUS_KEYSET_PATH'] = '/nonexistent/keyset.json'
      allow(Penetrator.logger).to receive(:warn)

      expect(described_class.adapter).to be_nil
      expect(Penetrator.logger).to have_received(:warn).with(/adapter construction failed/)
    end
  end

  # Self-fetching TP model (scanner#1182, arch#672) — on GCE the bus is
  # mandatory and construction is fail-loud, never silent-idle.
  describe 'on GCE (self-fetch, scanner#1182)' do
    before { allow(InstanceMetadata).to receive(:on_gce?).and_return(true) }

    it '.enabled? is unconditionally true, regardless of env vars' do
      expect(described_class.enabled?).to be(true)
    end

    it '.key_provider self-fetches via KeysetFetcher for the data-plane subjects' do
      provider = instance_double(Peregrine::Bus::StaticKeyProvider)
      fetcher = instance_double(Bus::KeysetFetcher, fetch: provider)
      allow(Bus::KeysetFetcher).to receive(:new).and_return(fetcher)

      expect(described_class.key_provider).to eq(provider)
      expect(fetcher).to have_received(:fetch).with(*Bus::AdapterEnv::DATA_PLANE_SUBJECTS)
    end

    it '.build_transport defaults to nats (not pubsub) and self-fetches creds, connecting direct to Synadia' do
      allow(Bus::NatsCredsFetcher).to receive(:new).and_return(instance_double(Bus::NatsCredsFetcher, fetch: '/dev/shm/peregrine/synadia.creds'))
      nats_class = stub_nats_connect!

      described_class.build_transport

      expect(nats_class).to have_received(:connect)
        .with('connect.ngs.global', user_credentials: '/dev/shm/peregrine/synadia.creds')
    end

    it '.adapter re-raises construction errors — fail-loud, never silent-idle' do
      ENV['BUS_BUCKET'] = 'bucket'
      stub_gcs_storage!
      stub_nats_connect!
      allow(Bus::NatsCredsFetcher).to receive(:new).and_return(instance_double(Bus::NatsCredsFetcher, fetch: '/dev/shm/peregrine/synadia.creds'))
      allow(Bus::KeysetFetcher).to receive(:new).and_raise(StandardError, 'no grant')

      expect { described_class.adapter }.to raise_error(StandardError, 'no grant')
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
