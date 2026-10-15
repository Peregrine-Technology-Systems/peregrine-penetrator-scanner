require 'sequel_helper'

RSpec.describe InstanceMetadata do
  let(:image_url) { "#{described_class::METADATA_BASE}/image" }

  before { described_class.reset! }
  after { described_class.reset! }

  describe '.boot_image' do
    it 'returns the short image name from a metadata self-link' do
      stub_request(:get, image_url)
        .with(headers: { 'Metadata-Flavor' => 'Google' })
        .to_return(status: 200, body: 'projects/peregrine-production/global/images/txn-scanner-app-20260628-v1-0-1')

      expect(described_class.boot_image).to eq('txn-scanner-app-20260628-v1-0-1')
    end

    it 'returns the value as-is when metadata has no path separators' do
      stub_request(:get, image_url).to_return(status: 200, body: 'bare-image-name')
      expect(described_class.boot_image).to eq('bare-image-name')
    end

    it 'returns UNKNOWN when metadata responds empty' do
      stub_request(:get, image_url).to_return(status: 200, body: "  \n")
      expect(described_class.boot_image).to eq(described_class::UNKNOWN)
    end

    it 'returns UNKNOWN on a non-success response (off-GCE / no metadata server)' do
      stub_request(:get, image_url).to_return(status: 404, body: 'not found')
      expect(described_class.boot_image).to eq(described_class::UNKNOWN)
    end

    it 'returns UNKNOWN (never raises) when the metadata server is unreachable' do
      stub_request(:get, image_url).to_timeout
      expect(described_class.boot_image).to eq(described_class::UNKNOWN)
    end

    it 'memoises — fetches the metadata server at most once' do
      stub = stub_request(:get, image_url).to_return(status: 200, body: 'img-1')

      2.times { described_class.boot_image }

      expect(stub).to have_been_requested.once
    end
  end

  describe '.tp_id' do
    let(:name_url) { "#{described_class::METADATA_BASE}/name" }

    around do |example|
      saved = ENV.fetch('HOSTNAME', nil)
      example.run
    ensure
      saved.nil? ? ENV.delete('HOSTNAME') : ENV['HOSTNAME'] = saved
    end

    it 'returns the GCE instance name as the tp-id' do
      stub_request(:get, name_url)
        .with(headers: { 'Metadata-Flavor' => 'Google' })
        .to_return(status: 200, body: 'txn-scanner-app-vm-1')

      expect(described_class.tp_id).to eq('txn-scanner-app-vm-1')
    end

    it 'falls back to $HOSTNAME off-GCE (metadata unreachable)' do
      stub_request(:get, name_url).to_return(status: 404)
      ENV['HOSTNAME'] = 'local-box'

      expect(described_class.tp_id).to eq('local-box')
    end

    it 'falls back to UNKNOWN off-GCE when $HOSTNAME is unset' do
      stub_request(:get, name_url).to_return(status: 404)
      ENV.delete('HOSTNAME')

      expect(described_class.tp_id).to eq(described_class::UNKNOWN)
    end

    it 'never raises when the metadata server times out' do
      stub_request(:get, name_url).to_timeout
      ENV['HOSTNAME'] = 'local-box'

      expect(described_class.tp_id).to eq('local-box')
    end

    it 'memoises — fetches the metadata server at most once' do
      stub = stub_request(:get, name_url).to_return(status: 200, body: 'vm-9')

      2.times { described_class.tp_id }

      expect(stub).to have_been_requested.once
    end
  end

  describe '.on_gce?' do
    let(:id_url) { "#{described_class::METADATA_BASE}/id" }

    it 'is true when the metadata server answers' do
      stub_request(:get, id_url).to_return(status: 200, body: '1234567890')

      expect(described_class.on_gce?).to be(true)
    end

    it 'is false off-GCE (metadata unreachable)' do
      stub_request(:get, id_url).to_return(status: 404)

      expect(described_class.on_gce?).to be(false)
    end

    it 'memoises — fetches the metadata server at most once' do
      stub = stub_request(:get, id_url).to_return(status: 200, body: '1')

      2.times { described_class.on_gce? }

      expect(stub).to have_been_requested.once
    end
  end
end
