# frozen_string_literal: true

require 'json'

# Conformance test for the probe output contract (docs/probe_contract.md) against
# the synthetic corpus (spec/support/synthetic_corpus.rb → spec/fixtures/synthetic_corpus).
#
# This doubles as the stable contract-test target the downstream analysis service
# writes against — it asserts the *shape* the scanner emits, not any analysis logic.
RSpec.describe 'Probe output contract' do
  corpus_dir = File.expand_path('../fixtures/synthetic_corpus', __dir__)
  realistic = JSON.parse(File.read(File.join(corpus_dir, 'realistic.json')))
  perturbed = JSON.parse(File.read(File.join(corpus_dir, 'perturbed.json')))
  manifest  = JSON.parse(File.read(File.join(corpus_dir, 'manifest.json')))

  rf = realistic['findings']
  pf = perturbed['findings']

  CORE_REQUIRED = %w[id scan_id detected_at probe source_tool finding_type title location].freeze
  VALID_SEVERITY = %w[critical high medium low info].freeze
  REFERENCE_PROBES = %w[web-dast template-cve injection content-discovery server-misconfig
                        tls sca secrets asset-discovery].freeze

  describe 'corpus integrity' do
    it 'has 100 realistic and 30 perturbed findings' do
      expect(rf.size).to eq(100)
      expect(pf.size).to eq(30)
    end

    it 'is stamped synthetic and flagged not-ground-truth' do
      expect(manifest['synthetic']).to be(true)
      expect(manifest['not_ground_truth']).to be_a(String).and(be_truthy)
      expect((rf + pf)).to all(satisfy { |f| f.dig('ext', 'synthetic', 'generated') == true })
    end

    it 'declares the contract version it was generated against' do
      expect(realistic['schema_version']).to eq(manifest['contract_version'])
    end
  end

  describe 'realistic series conforms to the contract' do
    it 'covers all nine reference probes' do
      expect(rf.map { |f| f['probe'] }.uniq).to match_array(REFERENCE_PROBES)
    end

    it 'every finding carries the required core fields' do
      rf.each do |f|
        CORE_REQUIRED.each { |k| expect(f[k]).not_to(be_nil, "missing #{k} in #{f['id']}") }
      end
    end

    it 'gives every finding a typed location with a kind' do
      expect(rf).to all(satisfy { |f| f['location'].is_a?(Hash) && !f.dig('location', 'kind').to_s.empty? })
    end

    it 'has at least one finding with a CVE and at least one without' do
      with_cve = rf.select { |f| (f['identifiers'] || []).any? { |i| i['type'] == 'cve' } }
      without_cve = rf.reject { |f| (f['identifiers'] || []).any? { |i| i['type'] == 'cve' } }
      expect(with_cve).not_to be_empty
      expect(without_cve).not_to be_empty
    end

    it 'preserves multiple identifiers losslessly (multi-CVE findings exist)' do
      multi = rf.count { |f| (f['identifiers'] || []).count { |i| i['type'] == 'cve' } > 1 }
      expect(multi).to be > 0
    end

    it 'uses {type,value} identifier entries' do
      rf.flat_map { |f| f['identifiers'] || [] }.each do |id|
        expect(id.keys).to match_array(%w[type value])
      end
    end

    it 'normalizes severity to the closed enum, null only for non-vulnerability findings' do
      rf.each do |f|
        if f['severity'].nil?
          expect(%w[asset informational]).to include(f['finding_type'])
        else
          expect(VALID_SEVERITY).to include(f['severity'])
        end
      end
    end

    it 'includes exact-duplicate fingerprints to exercise downstream dedup' do
      dup = rf.map { |f| f['fingerprint'] }.tally.values.any? { |n| n > 1 }
      expect(dup).to be(true)
    end
  end

  describe 'perturbed series' do
    it 'labels every finding escalate with a named perturbation' do
      pf.each do |f|
        expect(f.dig('ext', 'synthetic', 'label')).to eq('escalate')
        expect(f.dig('ext', 'synthetic', 'perturbation')).to be_a(String).and(be_truthy)
      end
    end

    it 'exercises a spread of distinct perturbation types' do
      types = pf.map { |f| f.dig('ext', 'synthetic', 'perturbation') }.uniq
      expect(types.size).to be >= 8
    end
  end

  describe 'envelope' do
    it 'keeps failed tools visible (a partial scan is not a clean one)' do
      executed = realistic.dig('tool_chain', 'executed')
      failed = executed.select { |t| t['status'] == 'failed' }
      expect(failed).not_to be_empty
      expect(failed).to all(satisfy { |t| t.key?('exit_code') && t.key?('findings_count') })
    end

    it 'carries optional substrate + vm_timing metadata that never gates enrichment' do
      meta = realistic['metadata']
      expect(meta['substrate']).to include('platform', 'machine_type', 'provisioning')
      expect(meta['vm_timing']).to include('wall_clock_seconds')
    end
  end
end
