# frozen_string_literal: true

RSpec.describe 'Docker image environment tagging' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }

  describe 'scan-vm.sh' do
    let(:script) { File.read(File.join(project_root, 'cloud/lib/scan-vm.sh')) }

    it 'defaults IMAGE_TAG to the environment name, not latest' do
      expect(script).not_to match(/IMAGE_TAG=.*latest/)
      expect(script).to match(/IMAGE_TAG.*\$\{3:-.*ENV/)
    end
  end

  describe 'trigger-scan.sh' do
    let(:script) { File.read(File.join(project_root, '.buildkite/scripts/trigger-scan.sh')) }

    it 'uses environment name as image tag in metadata' do
      expect(script).to match(/IMAGE_TAG=.*\$.*ENV/)
    end

    it 'does not default to latest' do
      expect(script).not_to match(/IMAGE_TAG=.*latest/)
    end
  end

  describe 'cloud/scheduler/main.py' do
    let(:script) { File.read(File.join(project_root, 'cloud/scheduler/main.py')) }

    it 'uses production as the image tag' do
      expect(script).to include("'IMAGE_TAG', value='production'")
    end
  end
end
