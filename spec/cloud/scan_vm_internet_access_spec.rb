# frozen_string_literal: true

RSpec.describe 'scan VM internet access' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }

  describe 'trigger-scan.sh' do
    let(:script) { File.read(File.join(project_root, '.buildkite/scripts/trigger-scan.sh')) }

    it 'does not use --no-address flag' do
      expect(script).not_to include('--no-address')
    end

    it 'creates VM with gcloud compute instances create' do
      expect(script).to include('gcloud compute instances create')
    end
  end

  describe 'scan-vm.sh' do
    let(:script) { File.read(File.join(project_root, 'cloud/lib/scan-vm.sh')) }

    it 'does not use --no-address flag' do
      expect(script).not_to include('--no-address')
    end
  end

  describe 'cloud/scheduler/main.py' do
    let(:script) { File.read(File.join(project_root, 'cloud/scheduler/main.py')) }

    it 'configures an access config for external IP on network interface' do
      expect(script).to include('AccessConfig')
    end
  end

  describe 'vm-startup.sh (lib)' do
    let(:script) { File.read(File.join(project_root, 'cloud/lib/vm-startup.sh')) }

    it 'has a trap for self-termination on failure' do
      expect(script).to match(/trap\b.*self_terminate/)
    end

    it 'defines a self_terminate function' do
      expect(script).to match(/self_terminate\(\)/)
    end
  end

  describe 'vm-startup.sh (scheduler)' do
    let(:script) { File.read(File.join(project_root, 'cloud/scheduler/vm-startup.sh')) }

    it 'has a trap for self-termination on failure' do
      expect(script).to match(/trap\b.*self_terminate/)
    end

    it 'defines a self_terminate function' do
      expect(script).to match(/self_terminate\(\)/)
    end
  end
end
