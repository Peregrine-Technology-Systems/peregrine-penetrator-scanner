# frozen_string_literal: true

RSpec.describe 'vm-startup.sh environment variables' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }

  # All env vars that the scanner needs passed through docker run
  let(:required_env_vars) do
    %w[
      SCAN_PROFILE
      SCAN_MODE
      APP_ENV
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

  shared_examples 'passes all required env vars' do |script_path|
    let(:script) { File.read(File.join(project_root, script_path)) }

    it 'includes all required env vars' do
      missing = required_env_vars.reject do |var|
        # Check both inline -e and bash array formats
        script.include?("-e \"#{var}=") ||
          script.include?("-e #{var}=") ||
          script.include?("-e \"#{var}\"") ||
          script.include?("-e \"#{var}")
      end

      expect(missing).to be_empty,
                         "Missing env vars: #{missing.join(', ')}. " \
                         'The scanner needs these but they are not passed through.'
    end
  end

  describe 'cloud/lib/vm-startup.sh' do
    include_examples 'passes all required env vars', 'cloud/lib/vm-startup.sh'
  end

  describe 'cloud/scheduler/vm-startup.sh' do
    include_examples 'passes all required env vars', 'cloud/scheduler/vm-startup.sh'
  end
end
