# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Probes::Catalog do
  describe '.all' do
    it 'has one entry per ScanOrchestrator::SCANNER_MAP tool, in lockstep' do
      expect(described_class.all.map(&:tool).sort).to eq(ScanOrchestrator::SCANNER_MAP.keys.sort)
    end

    it 'has durable, unique probe_ids' do
      ids = described_class.all.map(&:probe_id)
      expect(ids.uniq.length).to eq(ids.length)
    end
  end

  describe '.find' do
    it 'returns the probe entry for a known probe_id' do
      expect(described_class.find('zap').tool).to eq('zap')
    end

    it 'returns nil for an unknown probe_id' do
      expect(described_class.find('does-not-exist')).to be_nil
    end
  end

  describe '.tool_for' do
    it 'resolves a live probe_id to its tool' do
      expect(described_class.tool_for('nuclei')).to eq('nuclei')
    end

    it 'returns nil for an unknown probe_id' do
      expect(described_class.tool_for('does-not-exist')).to be_nil
    end
  end

  describe '.probe_id_for' do
    it 'resolves a tool key to its durable probe_id' do
      expect(described_class.probe_id_for('sqlmap')).to eq('sqlmap')
    end

    it 'returns nil for a tool with no catalog entry' do
      expect(described_class.probe_id_for('does-not-exist')).to be_nil
    end
  end

  describe '.resolve (retirement)' do
    it 'returns the id unchanged when it is not retired' do
      expect(described_class.resolve('zap')).to eq('zap')
    end

    it 'follows a single-hop retirement to the replacement id' do
      stub_const('Probes::Catalog::RETIRED', { 'old-id' => 'zap' }.freeze)
      expect(described_class.resolve('old-id')).to eq('zap')
    end

    it 'follows a multi-hop retirement chain' do
      stub_const('Probes::Catalog::RETIRED', { 'ancient-id' => 'old-id', 'old-id' => 'zap' }.freeze)
      expect(described_class.resolve('ancient-id')).to eq('zap')
    end

    it 'returns nil when retired with no replacement' do
      stub_const('Probes::Catalog::RETIRED', { 'dropped-id' => nil }.freeze)
      expect(described_class.resolve('dropped-id')).to be_nil
    end

    it 'raises on a cyclic retirement mapping rather than looping forever' do
      stub_const('Probes::Catalog::RETIRED', { 'a' => 'b', 'b' => 'a' }.freeze)
      expect { described_class.resolve('a') }.to raise_error(ArgumentError, /retirement cycle/)
    end
  end
end
