# frozen_string_literal: true

require 'sequel_helper'
require 'tempfile'

RSpec.describe Bus::JobPointerResolver do
  let(:subject_name) { Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'requested') }
  let(:substrate) { Peregrine::Bus::MemorySubstrate.new }
  let(:key_provider) { keyset_for(subject_name) }

  # Seals `payload` into `substrate` at a fresh blob_uri and returns the
  # matching ClaimCheck — the shape the launcher would write to the tmpfs
  # pointer file (minus the launcher's own metadata plumbing).
  def seal_and_point(payload)
    key_id = key_provider.current_key_id(subject_name)
    key = key_provider.key(key_id)
    envelope = Peregrine::Bus::Envelope.seal(subject: subject_name, key_id:, key:, plaintext: JSON.generate(payload))
    blob_uri = Peregrine::Bus::Subjects.object_path(subject_name, SecureRandom.uuid)
    substrate.put(blob_uri, envelope.to_json)
    Peregrine::Bus::ClaimCheck.new(subject: subject_name, blob_uri:, key_id:, ts: Time.current.iso8601, job_id: 'job-1')
  end

  def write_pointer_file(claim_check)
    file = Tempfile.new(['bus-job-pointer', '.json'])
    file.write(claim_check.to_json)
    file.flush
    file
  end

  describe '#resolve' do
    it 'returns nil when the pointer file does not exist (no-op, the only live path today)' do
      resolver = described_class.new(path: '/nonexistent/bus-job-pointer.json', substrate:, key_provider:)
      expect(resolver.resolve).to be_nil
    end

    it 'opens the sealed blob referenced by the pointer and returns the decoded job detail' do
      claim_check = seal_and_point('job_id' => 'job-1', 'transaction_id' => 'txn-1', 'environment' => 'production')
      file = write_pointer_file(claim_check)

      resolver = described_class.new(path: file.path, substrate:, key_provider:)
      expect(resolver.resolve).to eq('job_id' => 'job-1', 'transaction_id' => 'txn-1', 'environment' => 'production')
    ensure
      file&.unlink
    end

    it 'raises (fail-loud) when the pointer file exists but references a missing blob' do
      claim_check = Peregrine::Bus::ClaimCheck.new(subject: subject_name, blob_uri: 'data/task/penetrator/scan/requested/gone.json',
                                                   key_id: key_provider.current_key_id(subject_name), ts: Time.current.iso8601)
      file = write_pointer_file(claim_check)

      resolver = described_class.new(path: file.path, substrate:, key_provider:)
      expect { resolver.resolve }.to raise_error(KeyError)
    ensure
      file&.unlink
    end

    it 'raises (fail-loud) when the pointer file exists but is malformed JSON' do
      file = Tempfile.new(['bus-job-pointer', '.json'])
      file.write('not json')
      file.flush

      resolver = described_class.new(path: file.path, substrate:, key_provider:)
      expect { resolver.resolve }.to raise_error(Peregrine::Bus::ClaimCheck::MalformedError)
    ensure
      file&.unlink
    end

    it 'raises (fail-loud) when the sealed blob cannot be opened with the available keys' do
      claim_check = seal_and_point('job_id' => 'job-1')
      wrong_keys = keyset_for(Peregrine::Bus::Subjects::Penetrator.stage_state('scan', 'completed'))
      file = write_pointer_file(claim_check)

      resolver = described_class.new(path: file.path, substrate:, key_provider: wrong_keys)
      expect { resolver.resolve }.to raise_error(Peregrine::Bus::Envelope::UnknownKeyError)
    ensure
      file&.unlink
    end

    it 'defaults to AdapterEnv.substrate/.key_provider when not injected' do
      allow(Bus::AdapterEnv).to receive_messages(substrate: substrate, key_provider: key_provider)
      claim_check = seal_and_point('job_id' => 'job-1')
      file = write_pointer_file(claim_check)

      resolver = described_class.new(path: file.path)
      expect(resolver.resolve).to eq('job_id' => 'job-1')
    ensure
      file&.unlink
    end
  end
end
