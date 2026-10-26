# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::ScanSubjects do
  def with_env(env)
    allow(Penetrator).to receive(:env).and_return(env)
  end

  it 'is byte-identical to the unmarked subject in production' do
    with_env('production')

    expect(described_class.requested).to eq('peregrine.data.task.penetrator.scan.requested')
  end

  it 'carries the staging token in staging' do
    with_env('staging')

    expect(described_class.requested).to eq('peregrine.staging.data.task.penetrator.scan.requested')
    expect(described_class.terminal('failed')).to eq('peregrine.staging.data.task.penetrator.scan.failed')
  end

  it 'carries the dev token for development and test' do
    with_env('test')

    expect(described_class.terminal('completed')).to eq('peregrine.dev.data.task.penetrator.scan.completed')
  end

  it 'lists requested, completed and failed as the key-fetch set, in the current environment' do
    with_env('staging')

    expect(described_class.data_plane).to eq(
      %w[requested completed failed].map { |s| "peregrine.staging.data.task.penetrator.scan.#{s}" }
    )
  end
end
