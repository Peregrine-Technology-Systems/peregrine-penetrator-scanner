# frozen_string_literal: true

module Bus
  # Fans a single KeyProvider duck-type (`key(key_id)` / `current_key_id(subject)`)
  # out across N single-subject providers (scanner#1187 follow-up).
  #
  # peregrine-bus#70's `Peregrine::Bus::Gcp::SmKeyProvider` is scoped to exactly
  # one subject — `current_key_id` raises `KeyError` for any other subject,
  # verified directly against the shipped gcp-v0.3.0 source, not assumed from
  # the cross-repo summary that (incorrectly) described it as subject-set. One
  # scanner Adapter serves 3 data-plane subjects (scan.requested/completed/
  # failed) through a single key_provider, so this wrapper bridges that gap
  # without changing the gem's contract.
  class CompositeKeyProvider
    def self.for_subjects(*subjects, provider_class:, **opts)
      new(subjects.map { |subject| provider_class.new(subject:, **opts) })
    end

    def initialize(providers)
      @providers = providers
    end

    # Nil for any key_id none of the wrapped providers hold — matches
    # KeyProvider's own "no material for that id" contract, never raises here.
    def key(key_id)
      @providers.each do |provider|
        material = provider.key(key_id)
        return material if material
      end
      nil
    end

    # Delegates to whichever wrapped provider is scoped to `subject`; raises
    # KeyError (matching the wrapped providers' own fail-loud contract) if
    # none is.
    def current_key_id(subject)
      @providers.each do |provider|
        return provider.current_key_id(subject)
      rescue KeyError
        next
      end
      raise KeyError, "no key provider configured for subject #{subject.inspect}"
    end
  end
end
