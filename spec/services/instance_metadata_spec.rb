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
end
