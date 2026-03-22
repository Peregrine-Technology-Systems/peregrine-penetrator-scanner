# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Report do
  describe 'validations' do
    it 'validates format inclusion' do
      report = build(:report, format: 'invalid')
      expect(report.valid?).to be false
    end

    it 'validates status inclusion' do
      report = build(:report, status: 'invalid')
      expect(report.valid?).to be false
    end
  end

  describe 'associations' do
    it 'belongs to scan' do
      expect(Report.association_reflection(:scan)).not_to be_nil
      expect(Report.association_reflection(:scan)[:type]).to eq(:many_to_one)
    end
  end

  describe '#signed_url_valid?' do
    it 'returns false when expires_at is nil' do
      report = build(:report, signed_url_expires_at: nil)
      expect(report.signed_url_valid?).to be false
    end

    it 'returns true when not expired' do
      report = build(:report, signed_url_expires_at: 1.hour.from_now)
      expect(report.signed_url_valid?).to be true
    end

    it 'returns false when expired' do
      report = build(:report, signed_url_expires_at: 1.hour.ago)
      expect(report.signed_url_valid?).to be false
    end
  end
end
