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

    it 'allows nil ticket_tracker' do
      target = build(:target, ticket_tracker: nil)
      expect(target.valid?).to be true
    end

    it 'validates ticket_tracker inclusion when present' do
      target = build(:target, ticket_tracker: 'invalid')
      expect(target.valid?).to be false
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

  describe '#ticketing_enabled?' do
    it 'returns false without ticket_tracker' do
      target = build(:target, ticket_tracker: nil)
      expect(target.ticketing_enabled?).to be false
    end

    it 'returns true with tracker and config' do
      target = build(:target, :with_github_tickets)
      expect(target.ticketing_enabled?).to be true
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
