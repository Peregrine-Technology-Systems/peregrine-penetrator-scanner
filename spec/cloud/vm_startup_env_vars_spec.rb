# frozen_string_literal: true

RSpec.describe 'vm-startup.sh environment variables' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }

  # All env vars that the Rails app reads and needs passed through docker run
  let(:required_env_vars) do
    %w[
      SCAN_PROFILE
      SCAN_MODE
      RAILS_ENV
      TARGET_NAME
      TARGET_URLS
      ANTHROPIC_API_KEY
      NVD_API_KEY
      SLACK_WEBHOOK_URL
      NOTIFICATION_EMAIL
      SMTP_HOST
      SMTP_PORT
      SMTP_USERNAME
      SMTP_PASSWORD
      GCS_BUCKET
      GOOGLE_CLOUD_PROJECT
      VERSION
    ]
  end

  shared_examples 'passes all required env vars to docker run' do |script_path|
    let(:script) { File.read(File.join(project_root, script_path)) }

    # Extract the docker run block
    let(:docker_run_block) do
      match = script.match(/docker run .+?rake scan:run/m)
      expect(match).not_to be_nil, "Could not find 'docker run ... rake scan:run' block in #{script_path}"
      match[0]
    end

    required_env_vars_method = :required_env_vars

    it 'includes all required env vars in docker run' do
      missing = send(required_env_vars_method).reject do |var|
        docker_run_block.include?("-e \"#{var}=") ||
          docker_run_block.include?("-e #{var}=") ||
          docker_run_block.include?("-e \"#{var}")
      end

      expect(missing).to be_empty,
                         "Missing env vars in docker run: #{missing.join(', ')}. " \
                         'The Rails app needs these but they are not passed through.'
    end
  end

  describe 'cloud/lib/vm-startup.sh' do
    include_examples 'passes all required env vars to docker run', 'cloud/lib/vm-startup.sh'
  end

  describe 'cloud/scheduler/vm-startup.sh' do
    include_examples 'passes all required env vars to docker run', 'cloud/scheduler/vm-startup.sh'
  end
end
