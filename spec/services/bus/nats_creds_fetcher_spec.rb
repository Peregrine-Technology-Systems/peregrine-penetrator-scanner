# frozen_string_literal: true

require 'sequel_helper'
require 'tmpdir'
require 'google/cloud/secret_manager/v1'

RSpec.describe Bus::NatsCredsFetcher do
  let(:client) { instance_double(Google::Cloud::SecretManager::V1::SecretManagerService::Client) }
  let(:path) { File.join(Dir.mktmpdir, 'nested', 'synadia.creds') }
  let(:fetcher) { described_class.new(project: 'test-project', client:, path:) }

  def stub_secret(value)
    payload = Google::Cloud::SecretManager::V1::SecretPayload.new(data: value)
    response = Google::Cloud::SecretManager::V1::AccessSecretVersionResponse.new(payload:)
    allow(client).to receive(:access_secret_version)
      .with(name: "projects/test-project/secrets/#{described_class::SECRET_ID}/versions/latest")
      .and_return(response)
  end

  it 'writes the fetched creds content to the given path, mode 0600, and returns the path' do
    stub_secret("-----BEGIN NATS USER JWT-----\nfake\n------END NATS USER JWT------\n")

    result = fetcher.fetch

    expect(result).to eq(path)
    expect(File.read(path)).to include('BEGIN NATS USER JWT')
    expect(format('%o', File.stat(path).mode & 0o777)).to eq('600')
  end

  it 'raises rather than degrading when the secret is missing (fail-loud, scanner#1182)' do
    allow(client).to receive(:access_secret_version).and_raise(StandardError, 'denied')

    expect { fetcher.fetch }.to raise_error(StandardError, 'denied')
  end
end
