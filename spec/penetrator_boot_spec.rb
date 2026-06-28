# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Penetrator do
  describe '.root' do
    it 'returns a Pathname' do
      expect(described_class.root).to be_a(Pathname)
    end
  end

  describe '.logger' do
    it 'returns a Logger' do
      expect(described_class.logger).to be_a(Logger)
    end
  end

  describe '.env' do
    it 'returns test in test environment' do
      expect(described_class.env).to eq('test')
    end
  end

  describe '.db' do
    it 'returns a Sequel database connection' do
      expect(described_class.db).to be_a(Sequel::SQLite::Database)
    end

    it 'has the targets table' do
      expect(described_class.db.table_exists?(:targets)).to be true
    end

    it 'has the scans table' do
      expect(described_class.db.table_exists?(:scans)).to be true
    end

    it 'has the findings table' do
      expect(described_class.db.table_exists?(:findings)).to be true
    end

    it 'runs in WAL journal mode' do
      mode = described_class.db.fetch('PRAGMA journal_mode').first[:journal_mode]
      expect(mode).to eq('wal')
    end

    it 'has a 5-second busy timeout for SQLite-level write retry' do
      timeout = described_class.db.fetch('PRAGMA busy_timeout').first[:timeout]
      expect(timeout).to eq(5000)
    end
  end
end
