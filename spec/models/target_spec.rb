# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Target do
  describe 'validations' do
    it 'is valid with valid attributes' do
      target = build(:target)
      expect(target.valid?).to be true
    end

    it 'requires name' do
      target = build(:target, name: nil)
      expect(target.valid?).to be false
      expect(target.errors.on(:name)).not_to be_nil
    end

    it 'requires urls' do
      target = build(:target, urls: nil)
      expect(target.valid?).to be false
      expect(target.errors.on(:urls)).not_to be_nil
    end

    it 'validates auth_type inclusion' do
      target = build(:target, auth_type: 'invalid')
      expect(target.valid?).to be false
      expect(target.errors.on(:auth_type)).not_to be_nil
    end
  end

  describe 'associations' do
    it 'has many scans' do
      expect(Target.association_reflection(:scans)).not_to be_nil
      expect(Target.association_reflection(:scans)[:type]).to eq(:one_to_many)
    end
  end

  describe '#before_create' do
    it 'assigns a UUID' do
      target = create(:target)
      expect(target.id).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  describe '#url_list' do
    it 'returns array of URLs' do
      target = build(:target, urls: ['https://example.com'])
      expect(target.url_list).to eq(['https://example.com'])
    end

    it 'returns empty array for blank urls' do
      target = build(:target, urls: nil)
      # urls is required so we skip validation
      target.instance_variable_set(:@urls, nil)
      expect(target.url_list).to eq([])
    end
  end

  describe '.active' do
    it 'returns only active targets' do
      create(:target, active: true)
      create(:target, active: false)
      expect(Target.active.count).to eq(1)
    end
  end
end
