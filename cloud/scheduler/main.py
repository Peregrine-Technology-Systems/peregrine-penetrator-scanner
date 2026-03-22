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

    summary = f'Deleted: {len(deleted)}, Skipped: {len(skipped)}'
    return summary, 200


def trigger_scan(request):
    """HTTP Cloud Function to launch a production scan VM."""
    timestamp = int(time.time())
    instance_name = f'pentest-scan-prod-{timestamp}'

    # Read startup script
    startup_script_path = os.path.join(
        os.path.dirname(__file__), 'vm-startup.sh'
    )
    with open(startup_script_path, 'r') as f:
        startup_script = f.read()

    client = compute_v1.InstancesClient()

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
            compute_v1.Items(key='SCAN_MODE', value='production'),
            compute_v1.Items(key='SCAN_PROFILE', value='standard'),
            compute_v1.Items(key='TARGET_NAME', value='AuxScan Production'),
            compute_v1.Items(
                key='TARGET_URLS',
                value='["https://auxscan.app.data-estate.cloud"]',
            ),
            compute_v1.Items(
                key='GCS_BUCKET',
                value=f'{PROJECT}-pentest-reports',
            ),
            compute_v1.Items(
                key='REGISTRY',
                value=f'us-central1-docker.pkg.dev/{PROJECT}/pentest',
            ),
            compute_v1.Items(key='IMAGE_TAG', value='production'),
            compute_v1.Items(key='startup-script', value=startup_script),
        ]),
        scheduling=compute_v1.Scheduling(
            provisioning_model='SPOT',
            instance_termination_action='DELETE',
        ),
        labels={'env': 'production', 'project': 'pentest', 'scan': 'true'},
        tags=compute_v1.Tags(items=['pentest-scan']),
    )

    operation = client.insert(
        project=PROJECT, zone=ZONE, instance_resource=instance
    )
    operation.result()

    return f'Scan VM {instance_name} launched', 200
