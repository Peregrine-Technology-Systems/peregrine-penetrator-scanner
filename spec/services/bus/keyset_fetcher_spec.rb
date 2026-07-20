# frozen_string_literal: true

require 'sequel_helper'
require 'google/cloud/secret_manager/v1'

RSpec.describe Bus::KeysetFetcher do
  let(:client) { instance_double(Google::Cloud::SecretManager::V1::SecretManagerService::Client) }
  let(:fetcher) { described_class.new(project: 'test-project', client:) }
  let(:subject_name) { 'peregrine.data.task.penetrator.scan.requested' }
  let(:slug) { 'peregrine-data-task-penetrator-scan-requested' }
  let(:raw_32_bytes) { 'x' * 32 }
  let(:base64_of_32_bytes) { Base64.strict_encode64('y' * 32) }

  def stub_secret(secret_id, value)
    payload = Google::Cloud::SecretManager::V1::SecretPayload.new(data: value)
    response = Google::Cloud::SecretManager::V1::AccessSecretVersionResponse.new(payload:)
    allow(client).to receive(:access_secret_version)
      .with(name: "projects/test-project/secrets/#{secret_id}/versions/latest")
      .and_return(response)
  end

  it 'accepts RAW 32-byte key material, mirroring resolve_seal_key\'s primary path' do
    stub_secret("txn-monitor-cur--#{slug}", '3')
    stub_secret("txn-monitor-key--#{slug}-3", raw_32_bytes)

    provider = fetcher.fetch(subject_name)

    expect(provider.current_key_id(subject_name)).to eq("#{subject_name}:3")
    expect(provider.key("#{subject_name}:3")).to eq(raw_32_bytes)
  end

  it 'accepts a base64 form ONLY when it decodes to exactly 32 bytes (resolve_seal_key fallback)' do
    stub_secret("txn-monitor-cur--#{slug}", '3')
    stub_secret("txn-monitor-key--#{slug}-3", base64_of_32_bytes)

    provider = fetcher.fetch(subject_name)

    expect(provider.key("#{subject_name}:3")).to eq('y' * 32)
  end

  it 'raises on a wrong-length key — never accepts a corrupt/mis-sized key silently' do
    stub_secret("txn-monitor-cur--#{slug}", '1')
    stub_secret("txn-monitor-key--#{slug}-1", 'too-short')

    expect { fetcher.fetch(subject_name) }.to raise_error(/wrong-length key/)
  end

  it 'raises rather than degrading when a secret is missing (fail-loud, scanner#1182)' do
    allow(client).to receive(:access_secret_version).and_raise(StandardError, 'not found')

    expect { fetcher.fetch(subject_name) }.to raise_error(StandardError, 'not found')
  end

  it 'fetches multiple subjects into one combined keyset' do
    other_subject = 'peregrine.data.task.penetrator.scan.completed'
    other_slug = 'peregrine-data-task-penetrator-scan-completed'
    stub_secret("txn-monitor-cur--#{slug}", '1')
    stub_secret("txn-monitor-key--#{slug}-1", raw_32_bytes)
    stub_secret("txn-monitor-cur--#{other_slug}", '2')
    stub_secret("txn-monitor-key--#{other_slug}-2", raw_32_bytes)

    provider = fetcher.fetch(subject_name, other_subject)

    expect(provider.current_key_id(subject_name)).to eq("#{subject_name}:1")
    expect(provider.current_key_id(other_subject)).to eq("#{other_subject}:2")
  end

  it 'defaults to the peregrine-production project, matching infra\'s confirmed contract' do
    expect(described_class.new.instance_variable_get(:@project)).to eq('peregrine-production')
  end
end
