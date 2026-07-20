# frozen_string_literal: true

require 'sequel_helper'
require 'google/cloud/secret_manager/v1'

RSpec.describe Bus::KeysetFetcher do
  let(:client) { instance_double(Google::Cloud::SecretManager::V1::SecretManagerService::Client) }
  let(:fetcher) { described_class.new(project: 'test-project', client:) }
  let(:subject_name) { 'peregrine.data.task.penetrator.scan.requested' }
  let(:slug) { 'peregrine-data-task-penetrator-scan-requested' }

  def stub_secret(secret_id, value)
    payload = Google::Cloud::SecretManager::V1::SecretPayload.new(data: value)
    response = Google::Cloud::SecretManager::V1::AccessSecretVersionResponse.new(payload:)
    allow(client).to receive(:access_secret_version)
      .with(name: "projects/test-project/secrets/#{secret_id}/versions/latest")
      .and_return(response)
  end

  it 'fetches the current version and key material for each subject' do
    stub_secret("txn-monitor-cur--#{slug}", '3')
    stub_secret("txn-monitor-key--#{slug}-3", 'YmFzZTY0a2V5')

    provider = fetcher.fetch(subject_name)

    expect(provider.current_key_id(subject_name)).to eq("#{subject_name}:3")
    expect(provider.key("#{subject_name}:3")).to eq(Base64.strict_decode64('YmFzZTY0a2V5'))
  end

  it 'raises rather than degrading when a secret is missing (fail-loud, scanner#1182)' do
    allow(client).to receive(:access_secret_version).and_raise(StandardError, 'not found')

    expect { fetcher.fetch(subject_name) }.to raise_error(StandardError, 'not found')
  end

  it 'fetches multiple subjects into one combined keyset' do
    other_subject = 'peregrine.data.task.penetrator.scan.completed'
    other_slug = 'peregrine-data-task-penetrator-scan-completed'
    stub_secret("txn-monitor-cur--#{slug}", '1')
    stub_secret("txn-monitor-key--#{slug}-1", 'a2V5b25l')
    stub_secret("txn-monitor-cur--#{other_slug}", '2')
    stub_secret("txn-monitor-key--#{other_slug}-2", 'a2V5dHdv')

    provider = fetcher.fetch(subject_name, other_subject)

    expect(provider.current_key_id(subject_name)).to eq("#{subject_name}:1")
    expect(provider.current_key_id(other_subject)).to eq("#{other_subject}:2")
  end
end
