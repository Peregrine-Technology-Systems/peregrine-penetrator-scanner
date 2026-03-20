"""Cloud Function to launch ephemeral production scan VM."""

import os
import time

from google.cloud import compute_v1


PROJECT = os.environ.get('GCP_PROJECT', 'peregrine-pentest-dev')
ZONE = os.environ.get('GCP_ZONE', 'us-central1-a')
MACHINE_TYPE = f'zones/{ZONE}/machineTypes/e2-standard-4'
SERVICE_ACCOUNT = f'pentest-scanner@{PROJECT}.iam.gserviceaccount.com'
IMAGE_FAMILY = 'ubuntu-2204-lts'
IMAGE_PROJECT = 'ubuntu-os-cloud'


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
        )],
        service_accounts=[compute_v1.ServiceAccount(
            email=SERVICE_ACCOUNT,
            scopes=['https://www.googleapis.com/auth/cloud-platform'],
        )],
        metadata=compute_v1.Metadata(items=[
            compute_v1.Items(key='SCAN_MODE', value='production'),
            compute_v1.Items(key='SCAN_PROFILE', value='standard'),
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
