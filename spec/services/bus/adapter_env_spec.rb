# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::AdapterEnv do
  describe '.adapter' do
    it 'returns nil until the production substrate ships (disabled by default, scanner#1009)' do
      expect(described_class.adapter).to be_nil
    end
  end
end
