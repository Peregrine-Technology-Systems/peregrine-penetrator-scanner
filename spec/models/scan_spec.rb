# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Scan do
  describe 'validations' do
    it 'validates profile inclusion' do
      scan = build(:scan, profile: 'invalid')
      expect(scan.valid?).to be false
      expect(scan.errors.on(:profile)).not_to be_nil
    end

    it 'validates status inclusion' do
      scan = build(:scan, status: 'invalid')
      expect(scan.valid?).to be false
      expect(scan.errors.on(:status)).not_to be_nil
    end
  end

  describe 'associations' do
    it 'belongs to target' do
      expect(Scan.association_reflection(:target)).not_to be_nil
      expect(Scan.association_reflection(:target)[:type]).to eq(:many_to_one)
    end

    it 'has many findings' do
      expect(Scan.association_reflection(:findings)).not_to be_nil
    end

    it 'has many reports' do
      expect(Scan.association_reflection(:reports)).not_to be_nil
    end
  end

  describe '#duration' do
    it 'returns nil without timestamps' do
      scan = build(:scan)
      expect(scan.duration).to be_nil
    end

    it 'returns duration in seconds' do
      scan = build(:scan, started_at: Time.current - 300, completed_at: Time.current)
      expect(scan.duration).to be_within(1).of(300)
    end
  end

  describe '#finding_counts' do
    it 'returns severity counts' do
      scan = create(:scan)
      create(:finding, scan: scan, severity: 'high')
      create(:finding, scan: scan, severity: 'high')
      create(:finding, scan: scan, severity: 'low')

      counts = scan.finding_counts
      expect(counts['high']).to eq(2)
      expect(counts['low']).to eq(1)
    end
  end

  describe '.recent' do
    it 'orders by created_at descending' do
      create(:scan)
      # Ensure different timestamps
      sleep 0.01
      new_scan = create(:scan)
      expect(Scan.recent.first.id).to eq(new_scan.id)
    end
  end
end
