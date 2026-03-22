# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'idle-shutdown scripts' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:standalone_script) { File.read(File.join(project_root, 'cloud/lib/idle-shutdown.sh')) }
  let(:setup_vm_script) { File.read(File.join(project_root, 'cloud/lib/setup-vm.sh')) }

  # Extract the embedded idle-shutdown script from setup-vm.sh (between IDLE_EOF markers)
  let(:embedded_script) do
    match = setup_vm_script.match(/cat > "\$\{IDLE_SCRIPT\}" <<'IDLE_EOF'\n(.+?)\nIDLE_EOF/m)
    expect(match).not_to be_nil, 'Could not find embedded idle-shutdown script in setup-vm.sh'
    match[1]
  end

  shared_examples 'robust idle-shutdown script' do |script_accessor|
    subject(:script) { send(script_accessor) }

    it 'sets explicit PATH for cron environment' do
      expect(script).to include('export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"')
    end

    it 'uses --max-time on metadata curl to prevent hanging' do
      expect(script).to match(/curl --max-time \d+ .+-H "Metadata-Flavor: Google"/)
    end

    it 'uses --max-time on Slack notification curl' do
      expect(script).to match(/curl --max-time \d+ .+-X POST/)
    end

    it 'logs Slack notification success or failure' do
      expect(script).to include('Slack notification sent')
      expect(script).to include('Slack notification FAILED')
    end

    it 'logs when SLACK_WEBHOOK_URL is missing from metadata' do
      expect(script).to include('No SLACK_WEBHOOK_URL in metadata')
    end

    it 'sleeps after Slack notification to allow network buffer flush before shutdown' do
      # sleep must appear between the Slack curl and the shutdown command
      slack_pos = script.index('Slack notification sent')
      shutdown_pos = script.index('/sbin/shutdown')
      sleep_pos = script.index('sleep 2')
      expect(slack_pos).not_to be_nil
      expect(shutdown_pos).not_to be_nil
      expect(sleep_pos).not_to be_nil
      expect(sleep_pos).to be > slack_pos
      expect(sleep_pos).to be < shutdown_pos
    end
  end

  describe 'standalone idle-shutdown.sh' do
    include_examples 'robust idle-shutdown script', :standalone_script

    it 'starts with bash shebang' do
      expect(standalone_script).to start_with('#!/usr/bin/env bash')
    end
  end

  describe 'embedded script in setup-vm.sh' do
    include_examples 'robust idle-shutdown script', :embedded_script

    it 'is installed to /usr/local/bin/idle-shutdown-check.sh' do
      expect(setup_vm_script).to include('IDLE_SCRIPT="/usr/local/bin/idle-shutdown-check.sh"')
    end

    it 'has cron entry running every 5 minutes' do
      expect(setup_vm_script).to match(%r{CRON_ENTRY="\*/5 \* \* \* \* \$\{IDLE_SCRIPT\}})
    end
  end
end
