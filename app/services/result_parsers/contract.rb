# frozen_string_literal: true

module ResultParsers
  # Builds a probe-output-contract finding (docs/probe_contract.md, #971) from a
  # parser's tool-specific fields. Centralises the contract shape so the eight
  # finding parsers stay consistent. String keys throughout, matching the stored
  # (`Finding#data`) and exported form. `raw_ref` is deferred (nil) — see #971.
  module Contract
    module_function

    # rubocop:disable Metrics/ParameterLists -- a contract finding has many optional facets; this is the one place they're assembled.
    def finding(source_tool:, probe:, finding_type:, title:, location:,
                severity: nil, severity_source: nil, tool_check_id: nil,
                description: nil, identifiers: [], component: nil, scores: nil,
                confidence: nil, verified: nil, evidence: {})
      {
        'source_tool' => source_tool, 'probe' => probe, 'finding_type' => finding_type,
        'tool_check_id' => tool_check_id, 'title' => title, 'description' => description,
        'severity' => severity, 'severity_source' => severity_source,
        'confidence' => confidence, 'verified' => verified,
        'location' => location.compact, 'identifiers' => identifiers.compact,
        'component' => nonempty(component), 'scores' => nonempty(scores),
        'evidence' => evidence.compact, 'raw_ref' => nil
      }.compact
    end
    # rubocop:enable Metrics/ParameterLists

    def nonempty(hash)
      compacted = hash&.compact
      compacted && !compacted.empty? ? compacted : nil
    end

    def identifier(type, value)
      return nil if value.nil? || value.to_s.strip.empty?

      { 'type' => type, 'value' => value }
    end

    def web(url:, method: nil, parameter: nil)
      { 'kind' => 'web', 'url' => url, 'method' => method, 'parameter' => parameter }
    end

    def network(host:, port: nil, protocol: nil)
      { 'kind' => 'network', 'host' => host, 'port' => port, 'protocol' => protocol }
    end

    def package(name:, version: nil, ecosystem: nil)
      { 'kind' => 'package', 'name' => name, 'version' => version, 'ecosystem' => ecosystem }
    end

    def file(path:, line: nil, commit: nil)
      { 'kind' => 'file', 'path' => path, 'line' => line, 'commit' => commit }
    end
  end
end
