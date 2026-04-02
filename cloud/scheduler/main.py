"""Cloud Functions for pentest platform VM management."""

import json
import os
import time
from datetime import datetime, timezone

import urllib.request

from google.cloud import compute_v1


PROJECT = os.environ.get('GCP_PROJECT', 'peregrine-pentest-dev')
REGION = os.environ.get('GCP_REGION', 'us-central1')
ZONE = os.environ.get('GCP_ZONE', 'us-central1-a')
MACHINE_TYPE = f'zones/{ZONE}/machineTypes/e2-standard-4'
SERVICE_ACCOUNT = f'pentest-scanner@{PROJECT}.iam.gserviceaccount.com'
IMAGE_FAMILY = 'ubuntu-2204-lts'
IMAGE_PROJECT = 'ubuntu-os-cloud'
MAX_AGE_MINUTES = int(os.environ.get('MAX_AGE_MINUTES', '30'))


def _slack_notify(message):
    """Send a Slack notification. Fails silently."""
    url = os.environ.get('SLACK_WEBHOOK_URL', '')
    if not url:
        return
    payload = json.dumps({'text': message}).encode('utf-8')
    req = urllib.request.Request(
        url, data=payload,
        headers={'Content-Type': 'application/json'}
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass


def _check_vm_status(instance_name, zone_name):
    """SSH into VM to check scan container status.

    Returns a dict with:
      - alive: True if a scan container is running
      - containers: list of running container names
      - docker_ps: full docker ps output for logging
      - ssh_failed: True if SSH connection failed
    """
    import subprocess
    try:
        result = subprocess.run(
            [
                'gcloud', 'compute', 'ssh', instance_name,
                f'--zone={zone_name}',
                f'--project={PROJECT}',
                '--strict-host-key-checking=no',
                '--command=docker ps --format "{{.Names}} | {{.Status}} | {{.RunningFor}}"',
            ],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {'alive': False, 'containers': [], 'docker_ps': '',
                    'ssh_failed': True}

        output = result.stdout.strip()
        containers = [
            line for line in output.splitlines()
            if line.startswith('pentest-scan')
        ]
        return {
            'alive': len(containers) > 0,
            'containers': containers,
            'docker_ps': output,
            'ssh_failed': False,
        }
    except subprocess.TimeoutExpired:
        return {'alive': False, 'containers': [], 'docker_ps': '',
                'ssh_failed': True}
    except Exception:
        return {'alive': False, 'containers': [], 'docker_ps': '',
                'ssh_failed': True}


def scavenge_vms(request):
    """HTTP Cloud Function to delete orphaned scan VMs.

    Logic:
    - VMs younger than MAX_AGE_MINUTES: skip
    - VMs older than MAX_AGE_MINUTES but younger than HARD_MAX: SSH check
      - If scan container running: skip (still working)
      - If no container or SSH fails: delete (hung/idle)
    - VMs older than HARD_MAX_MINUTES: delete unconditionally
    """
    try:
        summary = _scavenge_vms_inner()
        return summary, 200
    except Exception as e:
        _slack_notify(
            f':rotating_light: *VM scavenger failed* — orphaned VMs '
            f'will NOT be cleaned up until this is fixed.\n'
            f'Error: `{e}`'
        )
        return f'ERROR: {e}', 500


def _scavenge_vms_inner():
    """Core scavenger logic, separated for error handling."""
    hard_max_minutes = int(os.environ.get('HARD_MAX_MINUTES', '240'))
    client = compute_v1.InstancesClient()
    now = datetime.now(timezone.utc)
    deleted = []
    skipped = []

    for zone_suffix in ['a', 'b', 'c', 'f']:
        zone_name = f'{REGION}-{zone_suffix}'
        try:
            instances = client.list(
                project=PROJECT, zone=zone_name,
                filter='name:pentest-scan-* AND status=RUNNING'
            )
        except Exception:
            continue

        for instance in instances:
            created_dt = datetime.fromisoformat(instance.creation_timestamp)
            age_minutes = (now - created_dt).total_seconds() / 60

            if age_minutes <= MAX_AGE_MINUTES:
                continue

            status = _check_vm_status(instance.name, zone_name)

            if age_minutes <= hard_max_minutes and status['alive']:
                skipped.append(
                    f'{instance.name} ({int(age_minutes)}m, active)'
                )
                continue

            if age_minutes > hard_max_minutes:
                reason = 'hard max exceeded (4h)'
            elif status['ssh_failed']:
                reason = 'SSH unreachable'
            else:
                reason = 'no active scan container'

            detail = (
                f'`{instance.name}` ({int(age_minutes)}m, {zone_name})\n'
                f'  Reason: {reason}'
            )
            if status['containers']:
                detail += (
                    f'\n  Killed containers:\n    '
                    + '\n    '.join(status['containers'])
                )
            elif status['docker_ps']:
                detail += f'\n  Docker state: {status["docker_ps"]}'
            elif status['ssh_failed']:
                detail += '\n  Could not SSH — VM unresponsive'

            try:
                operation = client.delete(
                    project=PROJECT, zone=zone_name,
                    instance=instance.name
                )
                operation.result()
                deleted.append(detail)
            except Exception as e:
                _slack_notify(
                    f':warning: Failed to delete orphaned VM '
                    f'`{instance.name}`: {e}'
                )

    parts = []
    if deleted:
        vm_list = '\n'.join(f'• {vm}' for vm in deleted)
        parts.append(
            f':wastebasket: Scavenged {len(deleted)} orphaned VM(s):\n'
            f'{vm_list}'
        )
    if skipped:
        skip_list = '\n'.join(f'• {vm}' for vm in skipped)
        parts.append(
            f':hourglass: Skipped {len(skipped)} active VM(s):\n{skip_list}'
        )
    if parts:
        _slack_notify('\n\n'.join(parts))

    return f'Deleted: {len(deleted)}, Skipped: {len(skipped)}'


def trigger_development(request):
    """Launch a scan VM in development mode (clone at boot)."""
    return _trigger_scan(request, default_mode='development',
                         default_tag='development')


def trigger_staging(request):
    """Launch a scan VM in staging mode (baked image)."""
    return _trigger_scan(request, default_mode='staging',
                         default_tag='staging')


def trigger_production(request):
    """Launch a scan VM in production mode (baked image, spot pricing)."""
    return _trigger_scan(request, default_mode='production',
                         default_tag='production')


def _trigger_scan(request, default_mode, default_tag):
    """Internal: launch a scan VM.

    Accepts optional JSON body from Reporter dispatch:
      - scan_uuid, profile, target_url, target_name, target_urls
      - callback_url, job_id, reporter_base_url
      - scan_mode, image_tag (override defaults from the environment function)

    The per-environment function sets sensible defaults; the caller can
    override scan_mode/image_tag if needed (e.g., to control scan depth).
    """
    data = request.get_json(silent=True) or {}

    scan_uuid = data.get('scan_uuid', f'scan-{int(time.time())}')
    profile = data.get('profile', 'standard')
    scan_mode = data.get('scan_mode', default_mode)
    image_tag = data.get('image_tag', default_tag)
    target_url = data.get('target_url',
                          'https://auxscan.app.data-estate.cloud')
    target_name = data.get('target_name', 'AuxScan Production')
    callback_url = data.get('callback_url', '')
    job_id = data.get('job_id', '')
    reporter_base_url = data.get('reporter_base_url', '')

    # Wrap single URL into JSON array for TARGET_URLS
    target_urls = data.get('target_urls')
    if target_urls is None:
        if target_url.startswith('['):
            target_urls = target_url
        else:
            target_urls = json.dumps([target_url])

    timestamp = int(time.time())
    instance_name = f'pentest-scan-{scan_uuid[:8]}-{timestamp}'

    # Read startup script
    startup_script_path = os.path.join(
        os.path.dirname(__file__), 'vm-startup.sh'
    )
    with open(startup_script_path, 'r') as f:
        startup_script = f.read()

    client = compute_v1.InstancesClient()

    # Production uses spot pricing for ~60% cost savings
    if scan_mode == 'production':
        scheduling = compute_v1.Scheduling(
            provisioning_model='SPOT',
            instance_termination_action='DELETE',
        )
    else:
        scheduling = compute_v1.Scheduling()

    instance = compute_v1.Instance(
        name=instance_name,
        machine_type=MACHINE_TYPE,
        disks=[compute_v1.AttachedDisk(
            auto_delete=True,
            boot=True,
            initialize_params=compute_v1.AttachedDiskInitializeParams(
                source_image=f'projects/{IMAGE_PROJECT}/global/images/family/{IMAGE_FAMILY}',
                disk_size_gb=30,
                disk_type=f'zones/{ZONE}/diskTypes/pd-standard',
            ),
        )],
        network_interfaces=[compute_v1.NetworkInterface(
            name='global/networks/default',
            access_configs=[compute_v1.AccessConfig(
                name='External NAT',
                type_='ONE_TO_ONE_NAT',
            )],
        )],
        service_accounts=[compute_v1.ServiceAccount(
            email=SERVICE_ACCOUNT,
            scopes=['https://www.googleapis.com/auth/cloud-platform'],
        )],
        metadata=compute_v1.Metadata(items=[
            compute_v1.Items(key='SCAN_MODE', value=scan_mode),
            compute_v1.Items(key='SCAN_PROFILE', value=profile),
            compute_v1.Items(key='TARGET_NAME', value=target_name),
            compute_v1.Items(key='TARGET_URLS', value=target_urls),
            compute_v1.Items(key='SCAN_UUID', value=scan_uuid),
            compute_v1.Items(key='CALLBACK_URL', value=callback_url),
            compute_v1.Items(key='JOB_ID', value=job_id),
            compute_v1.Items(
                key='REPORTER_BASE_URL', value=reporter_base_url,
            ),
            compute_v1.Items(
                key='GCS_BUCKET',
                value=f'{PROJECT}-pentest-reports',
            ),
            compute_v1.Items(
                key='REGISTRY',
                value=f'us-central1-docker.pkg.dev/{PROJECT}/pentest',
            ),
            compute_v1.Items(key='IMAGE_TAG', value=image_tag),
            compute_v1.Items(key='startup-script', value=startup_script),
        ]),
        scheduling=scheduling,
        labels={
            'env': scan_mode,
            'project': 'pentest',
            'scan': 'true',
            'profile': profile,
        },
        tags=compute_v1.Tags(items=['pentest-scan']),
    )

    operation = client.insert(
        project=PROJECT, zone=ZONE, instance_resource=instance
    )
    operation.result()

    return json.dumps({
        'scan_uuid': scan_uuid,
        'status': 'accepted',
        'instance_name': instance_name,
    }), 200, {'Content-Type': 'application/json'}
