require 'rails_helper'

RSpec.describe Report do
  describe 'validations' do
    it { is_expected.to validate_inclusion_of(:format).in_array(%w[json markdown html pdf]) }
    it { is_expected.to validate_inclusion_of(:status).in_array(%w[pending generating completed failed]) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:scan) }
  end

  describe '#signed_url_valid?' do
    it 'returns false when signed_url_expires_at is nil' do
      report = build(:report, signed_url_expires_at: nil)

      expect(report.signed_url_valid?).to be false
    end

    it 'returns true when signed_url_expires_at is in the future' do
      report = build(:report, signed_url_expires_at: 1.hour.from_now)

      expect(report.signed_url_valid?).to be true
    end

    it 'returns false when signed_url_expires_at is in the past' do
      report = build(:report, signed_url_expires_at: 1.hour.ago)

      expect(report.signed_url_valid?).to be false
    end

    it 'returns false when signed_url_expires_at is exactly now' do
      freeze_time do
        report = build(:report, signed_url_expires_at: Time.current)

        expect(report.signed_url_valid?).to be false
      end
    end
  end
end
