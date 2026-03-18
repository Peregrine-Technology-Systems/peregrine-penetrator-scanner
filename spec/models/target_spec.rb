require 'rails_helper'

RSpec.describe Target do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:urls) }
    it { is_expected.to validate_inclusion_of(:auth_type).in_array(%w[none basic bearer cookie]) }
  end

  describe 'associations' do
    it { is_expected.to have_many(:scans).dependent(:destroy) }
  end

  describe 'scopes' do
    describe '.active' do
      it 'returns only active targets' do
        active_target = create(:target, active: true)
        create(:target, active: false)

        expect(described_class.active).to eq([active_target])
      end
    end
  end

  describe '#url_list' do
    it 'returns parsed URLs when urls is a JSON string' do
      target = build(:target, urls: '["https://example.com", "https://test.com"]')

      expect(target.url_list).to eq(['https://example.com', 'https://test.com'])
    end

    it 'returns the array directly when urls is already an array' do
      target = build(:target, urls: ['https://example.com'])

      expect(target.url_list).to eq(['https://example.com'])
    end

    it 'returns empty array when urls is blank' do
      target = build(:target, urls: '')
      # urls presence validation would fail, but url_list handles blank
      expect(target.url_list).to eq([])
    end

    it 'returns empty array on invalid JSON' do
      target = build(:target)
      # Force an invalid JSON string past serialization
      allow(target).to receive(:urls).and_return('not-valid-json')

      expect(target.url_list).to eq([])
    end
  end

  describe 'UUID assignment' do
    it 'assigns a UUID on create' do
      target = create(:target)

      expect(target.id).to be_present
      expect(target.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end
  end

  describe 'serialized attributes' do
    it 'serializes and deserializes auth_config as JSON' do
      config = { 'username' => 'admin', 'password' => 'secret' }
      target = create(:target, auth_config: config)
      target.reload

      expect(target.auth_config).to eq(config)
    end

    it 'serializes and deserializes scope_config as JSON' do
      config = { 'include_paths' => ['/api'], 'exclude_paths' => ['/static'] }
      target = create(:target, scope_config: config)
      target.reload

      expect(target.scope_config).to eq(config)
    end

    it 'serializes and deserializes brand_config as JSON' do
      config = { 'company_name' => 'Test Corp', 'primary_color' => '#ff0000' }
      target = create(:target, brand_config: config)
      target.reload

      expect(target.brand_config).to eq(config)
    end
  end
end
