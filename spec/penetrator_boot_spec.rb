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

    it 'has the reports table' do
      expect(described_class.db.table_exists?(:reports)).to be true
    end
  end
end
