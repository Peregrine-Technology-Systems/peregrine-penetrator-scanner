# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::CompositeKeyProvider do
  let(:subject_a) { 'peregrine.data.task.penetrator.scan.requested' }
  let(:subject_b) { 'peregrine.data.task.penetrator.scan.completed' }
  let(:provider_a) { fake_provider(subject: subject_a, key_id: "#{subject_a}:1", material: 'key-a') }
  let(:provider_b) { fake_provider(subject: subject_b, key_id: "#{subject_b}:2", material: 'key-b') }
  let(:composite) { described_class.new([provider_a, provider_b]) }

  # A minimal stand-in for the real single-subject-scoped SmKeyProvider
  # contract: current_key_id raises KeyError for any subject it isn't scoped
  # to, key returns nil for any key_id it doesn't hold.
  def fake_provider(subject:, key_id:, material:)
    Struct.new(:scoped_subject, :key_id, :material) do
      def key(requested_key_id)
        requested_key_id == key_id ? material : nil
      end

      def current_key_id(requested_subject)
        raise KeyError, "scoped to #{scoped_subject.inspect}" unless requested_subject == scoped_subject

        key_id
      end
    end.new(subject, key_id, material)
  end

  describe '#current_key_id' do
    it 'delegates to whichever wrapped provider is scoped to the subject' do
      expect(composite.current_key_id(subject_a)).to eq("#{subject_a}:1")
      expect(composite.current_key_id(subject_b)).to eq("#{subject_b}:2")
    end

    it 'raises KeyError when no wrapped provider is scoped to the subject' do
      expect { composite.current_key_id('peregrine.data.task.penetrator.scan.failed') }
        .to raise_error(KeyError, /no key provider configured/)
    end
  end

  describe '#key' do
    it 'returns the material from whichever wrapped provider holds that key_id' do
      expect(composite.key("#{subject_a}:1")).to eq('key-a')
      expect(composite.key("#{subject_b}:2")).to eq('key-b')
    end

    it 'returns nil (never raises) for a key_id none of the wrapped providers hold' do
      expect(composite.key('unknown:99')).to be_nil
    end
  end

  describe '.for_subjects' do
    it 'builds one provider instance per subject via the given provider_class' do
      built = []
      provider_class = Class.new do
        define_method(:initialize) { |subject:, project:| built << [subject, project] }
      end

      described_class.for_subjects(subject_a, subject_b, provider_class:, project: 'test-project')

      expect(built).to eq([[subject_a, 'test-project'], [subject_b, 'test-project']])
    end
  end
end
