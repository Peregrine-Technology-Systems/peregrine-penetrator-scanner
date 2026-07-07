# frozen_string_literal: true

module Probes
  # The durable probe catalog (#1068): a stable, enumerable `probe_id` per
  # scanner, independent of both the scan-profile YAML tool key
  # (ScanOrchestrator::SCANNER_MAP) and the finding-level `probe` category
  # (docs/probe_contract.md §5, e.g. "web-dast") — those two already vary
  # independently of each other, and `probe_id` is a third, orthogonal axis:
  # the stable identifier the Analyzer's scan-profile/v1
  # `selected_probes[].probe_id` / `skip_list[].probe_id` reference.
  #
  # Today `probe_id` is identity-mapped to the SCANNER_MAP tool key — the
  # simplest stable choice while there is exactly one probe per tool. The
  # indirection exists so that never has to change even if that stops being
  # true (a tool splitting into multiple selectable probes, or being renamed).
  #
  # Retirement (#1068 acceptance: "if an id is retired, map it"): entries move
  # to RETIRED, never deleted, so a historical profile or coverage ledger that
  # references a retired id stays interpretable — `resolve` follows the chain
  # to the live id (or nil if dropped with no replacement).
  module Catalog
    Probe = Struct.new(:probe_id, :tool, :category, keyword_init: true)

    # `category` is the finding-level `probe` vocabulary value each tool emits
    # (docs/probe_categories.md "Probe → category quick reference"). amass has
    # no finding-level `probe` value (it emits discovered_urls, not findings),
    # so its category is descriptive only, not a `probe_contract.md` vocab value.
    PROBES = [
      Probe.new(probe_id: 'zap', tool: 'zap', category: 'web-dast'),
      Probe.new(probe_id: 'nuclei', tool: 'nuclei', category: 'template-cve'),
      Probe.new(probe_id: 'sqlmap', tool: 'sqlmap', category: 'injection'),
      Probe.new(probe_id: 'ffuf', tool: 'ffuf', category: 'content-discovery'),
      Probe.new(probe_id: 'nikto', tool: 'nikto', category: 'server-misconfig'),
      Probe.new(probe_id: 'testssl', tool: 'testssl', category: 'tls'),
      Probe.new(probe_id: 'retirejs', tool: 'retirejs', category: 'sca'),
      Probe.new(probe_id: 'trufflehog', tool: 'trufflehog', category: 'secrets'),
      Probe.new(probe_id: 'amass', tool: 'amass', category: 'recon'),
      Probe.new(probe_id: 'schemathesis', tool: 'schemathesis', category: 'api-fuzz')
    ].freeze

    # probe_id -> replacement probe_id, or nil if retired with no replacement.
    # Append-only — never edit or delete an existing key.
    RETIRED = {}.freeze

    module_function

    def all
      PROBES
    end

    def find(probe_id)
      PROBES.find { |p| p.probe_id == probe_id }
    end

    # The live SCANNER_MAP tool key for a probe_id, following retirement if
    # needed. nil if the id is unknown or terminally retired.
    def tool_for(probe_id)
      find(resolve(probe_id))&.tool
    end

    # The durable probe_id for a SCANNER_MAP tool key, or nil if the tool has
    # no catalog entry.
    def probe_id_for(tool)
      PROBES.find { |p| p.tool == tool }&.probe_id
    end

    # Follow the retirement chain to a live probe_id, or nil if the chain ends
    # in retirement-with-no-replacement. Raises on a cyclic mapping — a
    # configuration bug in RETIRED itself, not a runtime data problem.
    def resolve(probe_id)
      seen = []
      current = probe_id
      while RETIRED.key?(current)
        raise ArgumentError, "retirement cycle detected for #{probe_id.inspect}" if seen.include?(current)

        seen << current
        current = RETIRED[current]
        return nil if current.nil?
      end
      current
    end
  end
end
