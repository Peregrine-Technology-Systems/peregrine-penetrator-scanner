# frozen_string_literal: true

require 'sequel_helper'

# Mirrors the orchestrator's Orchestrator.GrammarEnv (lib/orchestrator/grammar_env.ex): the
# scanner and the orchestrator must put the SAME token on a subject or no message arrives.
RSpec.describe Bus::GrammarEnv do
  before { allow(Penetrator.logger).to receive(:warn) }

  {
    'production' => nil,
    'staging' => 'staging',
    'development' => 'dev',
    'dev' => 'dev',
    'test' => 'dev'
  }.each do |env, token|
    it "maps #{env.inspect} to #{token.inspect}" do
      expect(described_class.token(env)).to eq(token)
    end
  end

  it 'scopes an unknown environment to dev and says so; only an exact "production" is unmarked' do
    expect(described_class.token('Production')).to eq('dev')
    expect(described_class.token('prod')).to eq('dev')
    expect(Penetrator.logger).to have_received(:warn).with(/unknown deploy env "prod"/)
  end

  it 'reads the deploy environment from Penetrator.env by default' do
    allow(Penetrator).to receive(:env).and_return('staging')

    expect(described_class.token).to eq('staging')
  end
end
