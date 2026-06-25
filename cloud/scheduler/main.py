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
# Zone fallback order: primary zone, then same-region alternates, then
# cross-region zones. Scan VMs are stateless — any zone works. (#710)
FALLBACK_ZONES = os.environ.get('FALLBACK_ZONES', ','.join([
    'us-central1-a', 'us-central1-b', 'us-central1-f',
    'us-east1-b', 'us-east1-c',
    'us-west1-a', 'us-west1-b',
    'us-east4-a', 'us-east4-b',
])).split(',')
MACHINE_TYPE_NAME = 'e2-standard-4'
SERVICE_ACCOUNT = f'pentest-scanner@{PROJECT}.iam.gserviceaccount.com'
SCANNER_IMAGE_FAMILY = 'scanner-base'
MAX_AGE_MINUTES = int(os.environ.get('MAX_AGE_MINUTES', '10'))
HEARTBEAT_STALE_MINUTES = int(os.environ.get('HEARTBEAT_STALE_MINUTES', '5'))
GCS_BUCKET = os.environ.get('GCS_BUCKET', f'{PROJECT}-pentest-reports')


def _get_scanner_image_name():
    """Resolve the current Packer-baked scanner-base image name from GCE image family."""
    images_client = compute_v1.ImagesClient()
    image = images_client.get_from_family(project=PROJECT, family=SCANNER_IMAGE_FAMILY)
    return image.name


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


def _write_vm_created(scan_uuid, instance_name):
    """Write vm-created marker to GCS after successful VM provisioning.

    Provides a durable signal that the VM was created, even if
    vm-startup.sh fails before the scan container starts. (#711)
    """
    try:
        from google.cloud import storage as gcs
        client = gcs.Client(project=PROJECT)
        bucket = client.bucket(GCS_BUCKET)
        blob = bucket.blob(f'control/{scan_uuid}/vm-created.json')
        payload = json.dumps({
            'scan_uuid': scan_uuid,
            'instance_name': instance_name,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        })
        blob.upload_from_string(payload, content_type='application/json')
    except Exception as e:
        print(f'[trigger] Failed to write vm-created to GCS: {e}')


def _check_vm_status(instance_name, zone_name):
    """SSH into VM to check if a native scan process is running.

    With the Packer-native model (no Docker), liveness is determined by
    whether `bundle exec bin/scan` is running on the VM. (#903)

    Returns a dict with:
      - alive: True if a scan process is running (bundle exec bin/scan)
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
                '--command=pgrep -fa "bundle exec" | grep -q "bin/scan" && echo RUNNING || echo IDLE',
            ],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {'alive': False, 'ssh_failed': True}

        return {
            'alive': 'RUNNING' in result.stdout,
            'ssh_failed': False,
        }
    except subprocess.TimeoutExpired:
        return {'alive': False, 'ssh_failed': True}
    except Exception:
        return {'alive': False, 'ssh_failed': True}


def _check_heartbeat(scan_uuid):
    """Check GCS for recent heartbeat from a scan VM.

    Returns dict with:
      - has_heartbeat: True if heartbeat.json exists
      - stale_minutes: minutes since last heartbeat (None if no heartbeat)
      - current_tool: tool name from heartbeat (None if unavailable)
    """
    if not scan_uuid:
        return {'has_heartbeat': False, 'stale_minutes': None, 'current_tool': None}

    from google.cloud import storage as gcs
    try:
        client = gcs.Client(project=PROJECT)
        bucket = client.bucket(GCS_BUCKET)
        blob = bucket.blob(f'control/{scan_uuid}/heartbeat.json')
        if not blob.exists():
            return {'has_heartbeat': False, 'stale_minutes': None, 'current_tool': None}

        data = json.loads(blob.download_as_text())
        ts = datetime.fromisoformat(data['timestamp'])
        now = datetime.now(timezone.utc)
        stale_minutes = (now - ts).total_seconds() / 60
        return {
            'has_heartbeat': True,
            'stale_minutes': round(stale_minutes, 1),
            'current_tool': data.get('current_tool'),
        }
    except Exception as e:
        print(f'[vm-scavenger] Heartbeat check failed for {scan_uuid}: {e}')
        return {'has_heartbeat': False, 'stale_minutes': None, 'current_tool': None}


def _check_status(scan_uuid):
    """Check GCS for post-scan lifecycle status.

    Returns dict with:
      - has_status: True if status.json exists
      - phase: lifecycle phase (scanning, completed, uploading, uploaded,
               terminating, failed, upload_failed)
      - stale_minutes: minutes since status was written
    """
    if not scan_uuid:
        return {'has_status': False, 'phase': None, 'stale_minutes': None}

    from google.cloud import storage as gcs
    try:
        client = gcs.Client(project=PROJECT)
        bucket = client.bucket(GCS_BUCKET)
        blob = bucket.blob(f'control/{scan_uuid}/status.json')
        if not blob.exists():
            return {'has_status': False, 'phase': None, 'stale_minutes': None}

        data = json.loads(blob.download_as_text())
        ts = datetime.fromisoformat(data['timestamp'])
        now = datetime.now(timezone.utc)
        stale_minutes = (now - ts).total_seconds() / 60
        return {
            'has_status': True,
            'phase': data.get('phase'),
            'stale_minutes': round(stale_minutes, 1),
        }
    except Exception as e:
        print(f'[vm-scavenger] Status check failed for {scan_uuid}: {e}')
        return {'has_status': False, 'phase': None, 'stale_minutes': None}


def _get_scan_uuid(instance):
    """Extract SCAN_UUID from instance metadata."""
    if instance.metadata and instance.metadata.items:
        for item in instance.metadata.items:
            if item.key == 'SCAN_UUID':
                return item.value
    return None


def scavenge_vms(request):
    """HTTP Cloud Function to delete orphaned scan VMs.

    Routes:
    - GET any path → 200 OK health check (pollers use GET)
    - POST /health → 200 OK health check (belt-and-suspenders)
    - POST / → run scavenger logic (requires OIDC auth via Cloud Scheduler)

    Logic:
    - VMs younger than MAX_AGE_MINUTES: skip
    - VMs older than MAX_AGE_MINUTES but younger than HARD_MAX: SSH check
      - If scan container running: skip (still working)
      - If no container or SSH fails: delete (hung/idle)
    - VMs older than HARD_MAX_MINUTES: delete unconditionally
    """
    print(f'[vm-scavenger] method={request.method} path={request.path}')

    if request.method == 'GET' or request.path == '/health':
        return json.dumps({'status': 'ok', 'service': 'vm-scavenger'}), 200, {
            'Content-Type': 'application/json'}

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
    errors = []

    for zone_suffix in ['a', 'b', 'c', 'f']:
        zone_name = f'{REGION}-{zone_suffix}'
        try:
            all_instances = client.list(
                request={
                    'project': PROJECT,
                    'zone': zone_name,
                }
            )
        except Exception as e:
            print(f'ERROR listing VMs in {zone_name}: {e}')
            errors.append(f'{zone_name}: {e}')
            continue

        instances = [
            i for i in all_instances
            if i.name.startswith('pentest-scan-') and i.status == 'RUNNING'
        ]
        if instances:
            print(f'{zone_name}: found {len(instances)} scan VM(s)')

        for instance in instances:
            created_dt = datetime.fromisoformat(instance.creation_timestamp)
            age_minutes = (now - created_dt).total_seconds() / 60

            if age_minutes <= MAX_AGE_MINUTES:
                continue

            status = _check_vm_status(instance.name, zone_name)
            scan_uuid = _get_scan_uuid(instance)
            heartbeat = _check_heartbeat(scan_uuid)
            lifecycle = _check_status(scan_uuid)

            if age_minutes <= hard_max_minutes and status['alive']:
                # Container running — check heartbeat for actual progress
                if heartbeat['has_heartbeat'] and heartbeat['stale_minutes'] is not None:
                    if heartbeat['stale_minutes'] <= HEARTBEAT_STALE_MINUTES:
                        skipped.append(
                            f'{instance.name} ({int(age_minutes)}m, active, '
                            f'heartbeat {heartbeat["stale_minutes"]}m ago, '
                            f'tool: {heartbeat["current_tool"]})'
                        )
                        continue
                    # Heartbeat stale — scan is stuck despite container running
                else:
                    # No heartbeat — legacy scan or pre-heartbeat code
                    skipped.append(
                        f'{instance.name} ({int(age_minutes)}m, active, no heartbeat)'
                    )
                    continue

            # Container gone but VM alive — check post-scan lifecycle phase
            if (age_minutes <= hard_max_minutes and not status['alive']
                    and lifecycle['has_status']):
                phase = lifecycle['phase']
                phase_age = lifecycle['stale_minutes'] or 0
                if phase in ('uploading', 'completed', 'terminating') and phase_age <= HEARTBEAT_STALE_MINUTES:
                    skipped.append(
                        f'{instance.name} ({int(age_minutes)}m, '
                        f'post-scan phase: {phase}, {phase_age}m ago)'
                    )
                    continue

            if age_minutes > hard_max_minutes:
                reason = 'hard max exceeded (4h)'
            elif heartbeat.get('has_heartbeat') and heartbeat.get('stale_minutes', 0) > HEARTBEAT_STALE_MINUTES:
                reason = (f'heartbeat stale ({heartbeat["stale_minutes"]}m, '
                          f'last tool: {heartbeat.get("current_tool", "unknown")})')
            elif (lifecycle['has_status'] and lifecycle.get('stale_minutes', 0) > HEARTBEAT_STALE_MINUTES):
                reason = (f'post-scan phase stuck ({lifecycle["phase"]}, '
                          f'{lifecycle["stale_minutes"]}m ago)')
            elif status['ssh_failed']:
                reason = 'SSH unreachable'
            else:
                reason = 'no active scan container'

            detail = (
                f'`{instance.name}` ({int(age_minutes)}m, {zone_name})\n'
                f'  Reason: {reason}'
            )
            if status['ssh_failed']:
                detail += '\n  Could not SSH — VM unresponsive'
            elif status['alive']:
                detail += '\n  Scan process killed (bundle exec bin/scan was running)'

            try:
                operation = client.delete(
                    request={
                        'project': PROJECT,
                        'zone': zone_name,
                        'instance': instance.name,
                    }
                )
                operation.result()
                deleted.append(detail)
            except Exception as e:
                _slack_notify(
                    f':warning: Failed to delete orphaned VM '
                    f'`{instance.name}`: {e}'
                )

    parts = []
    if errors:
        err_list = '\n'.join(f'• {e}' for e in errors)
        parts.append(
            f':warning: *Scavenger zone errors* — some zones could '
            f'not be checked:\n{err_list}'
        )
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

    summary = (f'Deleted: {len(deleted)}, Skipped: {len(skipped)}, '
               f'Errors: {len(errors)}')
    print(summary)
    return summary


def trigger_development(request):
    """Launch a scan VM in development mode (clones development branch at boot)."""
    return _trigger_scan(request, default_mode='development',
                         default_branch='development')


def trigger_staging(request):
    """Launch a scan VM in staging mode (clones staging branch at boot)."""
    return _trigger_scan(request, default_mode='staging',
                         default_branch='staging')


def trigger_production(request):
    """Launch a scan VM in production mode (clones main branch at boot, SPOT)."""
    return _trigger_scan(request, default_mode='production',
                         default_branch='main')


def _trigger_scan(request, default_mode, default_branch):
    """Internal: launch a scan VM using the Packer-baked scanner-base image.

    Accepts JSON body from orchestrator/reporter dispatch:
      - callback_url (REQUIRED) — all heartbeats and completion callbacks go here
      - scan_uuid, profile, target_url, target_name, target_urls
      - job_id, reporter_base_url
      - scan_mode, scan_branch (override defaults from the environment function)

    The per-environment function sets sensible defaults; the caller can
    override scan_mode/scan_branch if needed (e.g., to control scan depth).
    The VM clones the specified git branch at boot — no Docker required. (#903)
    """
    print(f'[trigger-scan-{default_mode}] method={request.method} path={request.path}')

    if request.method == 'GET' or request.path == '/health':
        return json.dumps({
            'status': 'ok',
            'service': f'trigger-scan-{default_mode}',
        }), 200, {'Content-Type': 'application/json'}

    data = request.get_json(silent=True) or {}

    scan_uuid = data.get('scan_uuid', f'scan-{int(time.time())}')
    profile = data.get('profile', 'standard')
    scan_mode = data.get('scan_mode', default_mode)
    scan_branch = data.get('scan_branch', default_branch)
    target_url = data.get('target_url',
                          'https://auxscan.app.data-estate.cloud')
    target_name = data.get('target_name', 'AuxScan Production')
    callback_url = data.get('callback_url', '')
    if not callback_url:
        return json.dumps({
            'error': 'callback_url is required',
        }), 400, {'Content-Type': 'application/json'}

    job_id = data.get('job_id', '')
    reporter_base_url = data.get('reporter_base_url', '')

    # Wrap single URL into JSON array for TARGET_URLS
    target_urls = data.get('target_urls')
    if target_urls is None:
        if target_url.startswith('['):
            target_urls = target_url
        else:
            target_urls = json.dumps([target_url])
    elif isinstance(target_urls, list):
        target_urls = json.dumps(target_urls)

    timestamp = int(time.time())
    instance_name = f'pentest-scan-{scan_uuid[:8]}-{timestamp}'

    # Read startup script
    startup_script_path = os.path.join(
        os.path.dirname(__file__), 'vm-startup.sh'
    )
    with open(startup_script_path, 'r') as f:
        startup_script = f.read()

    # Resolve Packer-baked image — all scan VMs use the same toolchain image
    scanner_image_name = _get_scanner_image_name()

    client = compute_v1.InstancesClient()

    scheduling = compute_v1.Scheduling()

    # Try each zone in FALLBACK_ZONES until one has capacity (#710)
    created_zone = None
    last_error = None
    for zone in FALLBACK_ZONES:
        instance = compute_v1.Instance(
            name=instance_name,
            machine_type=f'zones/{zone}/machineTypes/{MACHINE_TYPE_NAME}',
            disks=[compute_v1.AttachedDisk(
                auto_delete=True,
                boot=True,
                initialize_params=compute_v1.AttachedDiskInitializeParams(
                    source_image=f'projects/{PROJECT}/global/images/{scanner_image_name}',
                    disk_size_gb=30,
                    disk_type=f'zones/{zone}/diskTypes/pd-standard',
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
                compute_v1.Items(key='SCAN_BRANCH', value=scan_branch),
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

        try:
            operation = client.insert(
                request={
                    'project': PROJECT,
                    'zone': zone,
                    'instance_resource': instance,
                }
            )
            operation.result()
            created_zone = zone
            break
        except Exception as e:
            last_error = str(e)
            print(f'[trigger-scan-{scan_mode}] Zone {zone} failed: '
                  f'{last_error[:200]}')

    if not created_zone:
        _slack_notify(
            f':x: VM creation failed for {scan_uuid} in all zones: '
            f'{last_error[:200]}')
        return json.dumps({
            'error': f'VM creation failed in all zones: {last_error}',
            'scan_uuid': scan_uuid,
        }), 503, {'Content-Type': 'application/json'}

    if created_zone != FALLBACK_ZONES[0]:
        print(f'[trigger-scan-{scan_mode}] Created in fallback zone '
              f'{created_zone} (primary {FALLBACK_ZONES[0]} exhausted)')

    # Write vm-created marker to GCS — closes the observability gap between
    # VM creation (confirmed by GCP API) and first heartbeat (~30s later).
    # If vm-startup.sh fails before the scan container starts, this is the
    # only durable signal that the VM was provisioned. (#711)
    _write_vm_created(scan_uuid, instance_name)

    return json.dumps({
        'scan_uuid': scan_uuid,
        'status': 'accepted',
        'instance_name': instance_name,
        'zone': created_zone,
    }), 200, {'Content-Type': 'application/json'}
