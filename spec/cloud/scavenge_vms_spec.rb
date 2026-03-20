# frozen_string_literal: true

RSpec.describe 'scavenge-vms.sh' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.read(File.join(project_root, 'cloud/lib/scavenge-vms.sh')) }

  it 'exists and is a bash script' do
    expect(script).to start_with('#!/usr/bin/env bash')
  end

  it 'only targets pentest-scan VMs, not the dev VM' do
    expect(script).to include('pentest-scan')
    expect(script).not_to match(/delete.*pentest-dev-vm/)
  end

  it 'filters VMs by age using creation timestamp' do
    expect(script).to match(/creationTimestamp|creation_timestamp/)
  end

  it 'has a configurable max age threshold' do
    expect(script).to match(/MAX_AGE|max_age/i)
  end

  it 'logs deletions' do
    expect(script).to match(/log|echo.*delet/i)
  end

  it 'sends Slack notification for orphan deletions' do
    expect(script).to include('slack_notify')
  end
end
