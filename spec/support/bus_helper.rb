# frozen_string_literal: true

require 'base64'

# Builds a real peregrine_bus adapter over an in-process MemorySubstrate + a static
# keyset, so the scanner's publish-side binding is exercised against the actual
# adapter (envelope + crypto + refuse-don't-deliver), not a fake (scanner#1009).
module BusHelper
  # A syntactically valid organization id for specs (envelope v2 requires a publisher organization).
  ORGANIZATION = '11111111-2222-4333-8444-555555555555'

  # A Bus::Publisher wrapping a MemorySubstrate adapter, plus the same adapter for
  # consuming what was published. Returns [publisher, adapter].
  def bus_pair(*subjects)
    substrate = Peregrine::Bus::MemorySubstrate.new
    transport = Peregrine::Bus::MemoryTransport.new
    adapter = Peregrine::Bus::Adapter.new(substrate:, transport:, key_provider: keyset_for(*subjects),
                                          account: Bus::GrammarEnv.account, organization_id: ORGANIZATION)
    [Bus::Publisher.new(adapter), adapter]
  end

  # Everything pending on `subject`, opened under ANY_ORGANIZATION, as plaintext strings.
  # (Envelope v2 consume requires an organization expectation and returns Opened pairs.)
  def consume_plain(adapter, subject)
    adapter.consume(subject, expected_organization_id: Peregrine::Bus::ANY_ORGANIZATION).map(&:plaintext)
  end

  # A static keyset holding a current key for each subject (+ its staging sibling).
  def keyset_for(*subjects, version: 1)
    current = {}
    keys = {}
    subjects.each do |s|
      # A dev-scoped subject has no staging sibling (the gem refuses to tee it), so key just itself.
      siblings = s.split('.')[1] == 'dev' ? [s] : [s, Peregrine::Bus::Subjects.tee_to_staging(s)]
      siblings.uniq.each do |subj|
        current[subj] = version
        # Key ids are scoped to the adapter's account (a dev adapter wants `dev:<subject>:<ver>`).
        keys[Peregrine::Bus::KeyScope.key_id(Bus::GrammarEnv.account, subj, version)] = Base64.strict_encode64(Peregrine::Bus::Sealer.random_key)
      end
    end
    Peregrine::Bus::StaticKeyProvider.from_hash('current' => current, 'keys' => keys)
  end
end
