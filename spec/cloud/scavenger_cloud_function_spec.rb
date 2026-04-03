# frozen_string_literal: true

RSpec.describe 'Cloud Function scavenger (main.py)' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.read(File.join(project_root, 'cloud/scheduler/main.py')) }

  describe 'scavenge_vms function' do
    it 'defines scavenge_vms HTTP entry point' do
      expect(script).to include('def scavenge_vms(request):')
    end

    it 'uses HTTP method as primary health check guard' do
      expect(script).to include("request.method == 'GET'")
    end

    it 'retains path-based health check as secondary guard' do
      expect(script).to include("request.path == '/health'")
    end

    it 'logs method and path on every invocation' do
      expect(script).to include('[vm-scavenger] method=')
    end

    it 'filters only pentest-scan VMs' do
      expect(script).to include("startswith('pentest-scan-')")
    end

    it 'filters only RUNNING VMs' do
      expect(script).to include("i.status == 'RUNNING'")
    end

    it 'checks multiple zones' do
      expect(script).to match(/zone_suffix.*\[.*'a'.*'b'.*'c'/)
    end

    it 'has a configurable max age threshold' do
      expect(script).to include('MAX_AGE_MINUTES')
    end

    it 'has a hard max age for unconditional deletion' do
      expect(script).to include('HARD_MAX_MINUTES')
      expect(script).to include("'240'")
    end
  end

  describe 'liveness check' do
    it 'defines _check_vm_status function' do
      expect(script).to include('def _check_vm_status(instance_name, zone_name):')
    end

    it 'SSHs into VM to check docker containers' do
      expect(script).to include('gcloud', 'compute', 'ssh')
      expect(script).to include('docker ps')
    end

    it 'identifies pentest-scan containers as alive' do
      expect(script).to include("line.startswith('pentest-scan')")
    end

    it 'handles SSH timeout gracefully' do
      expect(script).to include('TimeoutExpired')
    end

    it 'returns ssh_failed flag when SSH fails' do
      expect(script).to include("'ssh_failed': True")
    end

    it 'returns container details for Slack reporting' do
      expect(script).to include("'containers'")
      expect(script).to include("'docker_ps'")
    end
  end

  describe 'deletion logic' do
    it 'skips VMs younger than max age' do
      expect(script).to include('age_minutes <= MAX_AGE_MINUTES')
    end

    it 'skips active VMs under hard max' do
      expect(script).to match(/age_minutes <= hard_max_minutes.*alive/m)
    end

    it 'force deletes VMs over hard max regardless of liveness' do
      expect(script).to include('age_minutes > hard_max_minutes')
      expect(script).to include('hard max exceeded')
    end

    it 'deletes SSH-unreachable VMs' do
      expect(script).to include('SSH unreachable')
    end

    it 'deletes idle VMs with no active scan container' do
      expect(script).to include('no active scan container')
    end
  end

  describe 'Slack notifications' do
    it 'reports deleted VMs with details' do
      expect(script).to include('Scavenged')
      expect(script).to include(':wastebasket:')
    end

    it 'reports skipped active VMs' do
      expect(script).to include('Skipped')
      expect(script).to include(':hourglass:')
    end

    it 'includes killed container info in notification' do
      expect(script).to include('Killed containers')
    end

    it 'includes deletion reason in notification' do
      expect(script).to include('Reason:')
    end

    it 'reports SSH unreachable status' do
      expect(script).to include('Could not SSH')
    end

    it 'reports delete failures' do
      expect(script).to include('Failed to delete orphaned VM')
    end
  end

  describe 'trigger function health guard' do
    it 'uses HTTP method as primary health check guard' do
      expect(script).to include("request.method == 'GET'")
    end

    it 'retains path-based health check as secondary guard' do
      expect(script).to include("request.path == '/health'")
    end

    it 'logs method and path on every trigger invocation' do
      expect(script).to include('[trigger-scan-')
    end

    it 'returns service name in health response' do
      expect(script).to include("'service'")
    end
  end
end
