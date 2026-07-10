# frozen_string_literal: true

require 'base64'

# Builds a real peregrine_bus adapter over an in-process MemorySubstrate + a static
# keyset, so the scanner's publish-side binding is exercised against the actual
# adapter (envelope + crypto + refuse-don't-deliver), not a fake (scanner#1009).
module BusHelper
  # A Bus::Publisher wrapping a MemorySubstrate adapter, plus the same adapter for
  # consuming what was published. Returns [publisher, adapter].
  def bus_pair(*subjects)
    substrate = Peregrine::Bus::MemorySubstrate.new
    transport = Peregrine::Bus::MemoryTransport.new
    adapter = Peregrine::Bus::Adapter.new(substrate:, transport:, key_provider: keyset_for(*subjects))
    [Bus::Publisher.new(adapter), adapter]
  end

  # A static keyset holding a current key for each subject (+ its staging sibling).
  def keyset_for(*subjects, version: 1)
    current = {}
    keys = {}
    subjects.each do |s|
      [s, Peregrine::Bus::Subjects.tee_to_staging(s)].uniq.each do |subj|
        current[subj] = version
        keys["#{subj}:#{version}"] = Base64.strict_encode64(Peregrine::Bus::Sealer.random_key)
      end
    end
    Peregrine::Bus::StaticKeyProvider.from_hash('current' => current, 'keys' => keys)
  end
end
