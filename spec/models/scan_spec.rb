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
  end

  describe '#before_create' do
    it 'generates a UUID when no SCAN_UUID is set' do
      scan = create(:scan)
      expect(scan.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'uses SCAN_UUID from environment when set' do
      trigger_uuid = 'aabbccdd-1234-5678-9012-abcdef123456'
      stub_const('ENV', ENV.to_h.merge('SCAN_UUID' => trigger_uuid))
      scan = create(:scan)
      expect(scan.id).to eq(trigger_uuid)
    end

    it 'does not override an explicitly provided ID' do
      explicit_id = 'explicit-0000-1111-2222-333344445555'
      scan = create(:scan, id: explicit_id)
      expect(scan.id).to eq(explicit_id)
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
