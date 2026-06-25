# frozen_string_literal: true

RSpec.describe 'Scan VM git branch mapping' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }

  describe 'scan-vm.sh' do
    let(:script) { File.read(File.join(project_root, 'cloud/lib/scan-vm.sh')) }

    it 'defaults IMAGE_TAG to the environment name, not latest' do
      expect(script).not_to match(/IMAGE_TAG=.*latest/)
      expect(script).to match(/IMAGE_TAG.*\$\{3:-.*ENV/)
    end
  end

  describe 'trigger-scan.sh' do
    let(:script) { File.read(File.join(project_root, 'scripts/woodpecker/trigger-scan.sh')) }

    it 'maps each environment to a specific git branch' do
      expect(script).to include('SCAN_BRANCH="development"')
      expect(script).to include('SCAN_BRANCH="staging"')
      expect(script).to include('SCAN_BRANCH="main"')
    end

    it 'does not use IMAGE_TAG or Docker registry' do
      expect(script).not_to include('IMAGE_TAG=')
      expect(script).not_to include('REGISTRY=')
    end

    it 'resolves Packer image from SM pointer' do
      expect(script).to include('scanner-base--vm-base-image')
    end
  end

  describe 'cloud/scheduler/main.py' do
    let(:script) { File.read(File.join(project_root, 'cloud/scheduler/main.py')) }

    it 'uses default_branch for production' do
      expect(script).to include("default_branch='main'")
    end

    it 'does not use default_tag or IMAGE_TAG' do
      expect(script).not_to include('default_tag=')
      expect(script).not_to include("'IMAGE_TAG'")
    end
  end
end
