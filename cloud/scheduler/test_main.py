"""Tests for Cloud Function VM scavenger and trigger functions."""

import json
import os
import subprocess
import unittest
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock, patch

import flask

os.environ['GCP_PROJECT'] = 'test-project'
os.environ['GCP_REGION'] = 'us-central1'
os.environ['MAX_AGE_MINUTES'] = '30'
os.environ['HARD_MAX_MINUTES'] = '240'

import main  # noqa: E402


def _build_request(method='GET', path='/health', json_body=None):
    """Build a real Flask request object for testing."""
    app = flask.Flask(__name__)
    with app.test_request_context(path, method=method, json=json_body):
        return flask.request._get_current_object()


class TestSlackNotify(unittest.TestCase):
    @patch.dict(os.environ, {'SLACK_WEBHOOK_URL': ''})
    def test_no_op_without_webhook_url(self):
        with patch('urllib.request.urlopen') as mock_open:
            main._slack_notify('test')
            mock_open.assert_not_called()

    @patch.dict(os.environ, {'SLACK_WEBHOOK_URL': 'https://hooks.slack.com/test'})
    @patch('urllib.request.urlopen')
    def test_sends_json_payload(self, mock_open):
        main._slack_notify('hello')
        mock_open.assert_called_once()
        req = mock_open.call_args[0][0]
        self.assertEqual(req.get_header('Content-type'), 'application/json')
        body = json.loads(req.data)
        self.assertEqual(body['text'], 'hello')

    @patch.dict(os.environ, {'SLACK_WEBHOOK_URL': 'https://hooks.slack.com/test'})
    @patch('urllib.request.urlopen', side_effect=Exception('timeout'))
    def test_fails_silently_on_error(self, mock_open):
        main._slack_notify('hello')  # Should not raise


class TestCheckVmStatus(unittest.TestCase):
    @patch('subprocess.run')
    def test_active_scan_container(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout='pentest-scan-20260320 | Up 2 hours | 2 hours ago\n'
        )
        status = main._check_vm_status('vm-1', 'us-central1-a')
        self.assertTrue(status['alive'])
        self.assertEqual(len(status['containers']), 1)
        self.assertFalse(status['ssh_failed'])

    @patch('subprocess.run')
    def test_no_scan_container(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout='buildkit | Up 5 hours | 5 hours ago\n'
        )
        status = main._check_vm_status('vm-1', 'us-central1-a')
        self.assertFalse(status['alive'])
        self.assertEqual(len(status['containers']), 0)

    @patch('subprocess.run')
    def test_ssh_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=255, stdout='')
        status = main._check_vm_status('vm-1', 'us-central1-a')
        self.assertFalse(status['alive'])
        self.assertTrue(status['ssh_failed'])

    @patch('subprocess.run', side_effect=subprocess.TimeoutExpired('cmd', 30))
    def test_ssh_timeout(self, mock_run):
        status = main._check_vm_status('vm-1', 'us-central1-a')
        self.assertFalse(status['alive'])
        self.assertTrue(status['ssh_failed'])


class TestHealthEndpoints(unittest.TestCase):
    """Health endpoint tests using real Flask request objects.

    Primary guard: GET any path returns health (HTTP semantics — GET is safe).
    Secondary guard: POST /health returns health (belt-and-suspenders).
    """

    # --- Scavenger ---

    def test_scavenger_get_health(self):
        body, code, headers = main.scavenge_vms(
            _build_request('GET', '/health'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['service'], 'vm-scavenger')
        self.assertEqual(headers['Content-Type'], 'application/json')

    def test_scavenger_get_root_returns_health(self):
        """GET / must NOT trigger scavenger — primary method guard."""
        body, code, _ = main.scavenge_vms(
            _build_request('GET', '/'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')

    def test_scavenger_get_any_path_returns_health(self):
        """GET /anything must return health — method guard is unconditional."""
        body, code, _ = main.scavenge_vms(
            _build_request('GET', '/random'))
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['status'], 'ok')

    def test_scavenger_post_health_returns_health(self):
        """POST /health returns health — secondary path guard."""
        body, code, _ = main.scavenge_vms(
            _build_request('POST', '/health'))
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['status'], 'ok')

    # --- Trigger ---

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_get_health(self):
        body, code, headers = main.trigger_production(
            _build_request('GET', '/health'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(result['service'], 'trigger-scan-production')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_get_root_returns_health(self):
        """GET / must NOT trigger a scan — primary method guard."""
        body, code, _ = main.trigger_production(
            _build_request('GET', '/'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_get_any_path_returns_health(self):
        """GET /random must return health — method guard is unconditional."""
        body, code, _ = main.trigger_production(
            _build_request('GET', '/whatever'))
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['status'], 'ok')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_post_health_returns_health(self):
        """POST /health returns health — secondary path guard."""
        body, code, _ = main.trigger_production(
            _build_request('POST', '/health'))
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['status'], 'ok')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_post_root_creates_vm(self, mock_cls):
        """POST / triggers scan — verify method guard doesn't block."""
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        body, code, _ = main.trigger_production(
            _build_request('POST', '/', json_body={}))
        result = json.loads(body)
        self.assertEqual(result['status'], 'accepted')
        client.insert.assert_called_once()

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_development_health_includes_service_name(self):
        body, code, _ = main.trigger_development(
            _build_request('GET', '/health'))
        result = json.loads(body)
        self.assertEqual(result['service'], 'trigger-scan-development')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_staging_health_includes_service_name(self):
        body, code, _ = main.trigger_staging(
            _build_request('GET', '/health'))
        result = json.loads(body)
        self.assertEqual(result['service'], 'trigger-scan-staging')


class TestCheckStatus(unittest.TestCase):
    def test_returns_no_status_for_none_uuid(self):
        result = main._check_status(None)
        self.assertFalse(result['has_status'])
        self.assertIsNone(result['phase'])

    def test_returns_no_status_for_empty_uuid(self):
        result = main._check_status('')
        self.assertFalse(result['has_status'])

    @patch('google.cloud.storage.Client')
    def test_returns_status_when_exists(self, mock_gcs_cls):
        mock_client = MagicMock()
        mock_gcs_cls.return_value = mock_client
        mock_bucket = MagicMock()
        mock_client.bucket.return_value = mock_bucket
        mock_blob = MagicMock()
        mock_bucket.blob.return_value = mock_blob
        mock_blob.exists.return_value = True
        ts = datetime.now(timezone.utc) - timedelta(minutes=2)
        mock_blob.download_as_text.return_value = json.dumps({
            'phase': 'uploading',
            'timestamp': ts.isoformat(),
        })

        result = main._check_status('uuid-123')
        self.assertTrue(result['has_status'])
        self.assertEqual(result['phase'], 'uploading')
        self.assertAlmostEqual(result['stale_minutes'], 2.0, delta=0.5)

    @patch('google.cloud.storage.Client')
    def test_returns_no_status_when_blob_missing(self, mock_gcs_cls):
        mock_client = MagicMock()
        mock_gcs_cls.return_value = mock_client
        mock_bucket = MagicMock()
        mock_client.bucket.return_value = mock_bucket
        mock_blob = MagicMock()
        mock_bucket.blob.return_value = mock_blob
        mock_blob.exists.return_value = False

        result = main._check_status('uuid-123')
        self.assertFalse(result['has_status'])
        self.assertIsNone(result['phase'])


class TestScavengeVms(unittest.TestCase):
    def _make_instance(self, name, age_minutes, status='RUNNING'):
        created = datetime.now(timezone.utc) - timedelta(minutes=age_minutes)
        inst = MagicMock()
        inst.name = name
        inst.status = status
        inst.creation_timestamp = created.isoformat()
        return inst

    @staticmethod
    def _single_zone_list(*instances):
        """Return instances for first zone only (4 zones: a, b, c, f)."""
        return [list(instances), [], [], []]

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_skips_young_vms(self, mock_client_cls, mock_check, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        young_vm = self._make_instance('pentest-scan-young', 10)
        client.list.side_effect = self._single_zone_list(young_vm)

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertEqual(code, 200)
        client.delete.assert_not_called()
        mock_check.assert_not_called()

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_skips_active_vm_under_hard_max(self, mock_client_cls, mock_check,
                                            mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        active_vm = self._make_instance('pentest-scan-active', 60)
        client.list.side_effect = self._single_zone_list(active_vm)
        mock_check.return_value = {
            'alive': True, 'containers': ['pentest-scan-1'],
            'docker_ps': '', 'ssh_failed': False
        }

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertIn('Skipped: 1', body)
        client.delete.assert_not_called()

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_deletes_idle_vm_over_max_age(self, mock_client_cls, mock_check,
                                          mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        idle_vm = self._make_instance('pentest-scan-idle', 45)
        client.list.side_effect = self._single_zone_list(idle_vm)
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertIn('Deleted: 1', body)
        client.delete.assert_called_once()

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_force_deletes_over_hard_max(self, mock_client_cls, mock_check,
                                         mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        old_vm = self._make_instance('pentest-scan-old', 300)
        client.list.side_effect = self._single_zone_list(old_vm)
        mock_check.return_value = {
            'alive': True, 'containers': ['pentest-scan-1'],
            'docker_ps': '', 'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertIn('Deleted: 1', body)
        client.delete.assert_called_once()

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_deletes_ssh_unreachable_vm(self, mock_client_cls, mock_check,
                                        mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        hung_vm = self._make_instance('pentest-scan-hung', 45)
        client.list.side_effect = self._single_zone_list(hung_vm)
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': True
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertIn('Deleted: 1', body)
        slack_msg = mock_slack.call_args[0][0]
        self.assertIn('SSH unreachable', slack_msg)

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_slack_includes_container_info_on_hard_kill(
            self, mock_client_cls, mock_check, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        vm = self._make_instance('pentest-scan-busy', 300)
        client.list.side_effect = self._single_zone_list(vm)
        mock_check.return_value = {
            'alive': True,
            'containers': ['pentest-scan-20260320 | Up 5 hours | 5h ago'],
            'docker_ps': 'pentest-scan-20260320 | Up 5 hours | 5h ago',
            'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        main.scavenge_vms(_build_request('POST', '/'))
        slack_msg = mock_slack.call_args[0][0]
        self.assertIn('Killed containers', slack_msg)
        self.assertIn('pentest-scan-20260320', slack_msg)

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_status')
    @patch.object(main, '_check_heartbeat')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_skips_vm_in_uploading_phase(self, mock_client_cls, mock_check,
                                         mock_hb, mock_status, mock_slack):
        """VM with no container but fresh 'uploading' status = skip."""
        client = MagicMock()
        mock_client_cls.return_value = client
        vm = self._make_instance('pentest-scan-uploading', 45)
        vm.metadata = MagicMock()
        vm.metadata.items = [MagicMock(key='SCAN_UUID', value='uuid-up')]
        client.list.side_effect = self._single_zone_list(vm)
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': False
        }
        mock_hb.return_value = {
            'has_heartbeat': False, 'stale_minutes': None, 'current_tool': None
        }
        mock_status.return_value = {
            'has_status': True, 'phase': 'uploading', 'stale_minutes': 1.0
        }

        body, code = main.scavenge_vms(_build_request('POST', '/'))
        self.assertIn('Skipped: 1', body)
        client.delete.assert_not_called()

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_status')
    @patch.object(main, '_check_heartbeat')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_deletes_vm_stuck_in_uploading_phase(self, mock_client_cls,
                                                  mock_check, mock_hb,
                                                  mock_status, mock_slack):
        """VM stuck in 'uploading' for >5m = delete."""
        client = MagicMock()
        mock_client_cls.return_value = client
        vm = self._make_instance('pentest-scan-stuck-upload', 45)
        vm.metadata = MagicMock()
        vm.metadata.items = [MagicMock(key='SCAN_UUID', value='uuid-stuck')]
        client.list.side_effect = self._single_zone_list(vm)
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': False
        }
        mock_hb.return_value = {
            'has_heartbeat': False, 'stale_minutes': None, 'current_tool': None
        }
        mock_status.return_value = {
            'has_status': True, 'phase': 'uploading', 'stale_minutes': 10.0
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(_build_request('POST', '/'))
        self.assertIn('Deleted: 1', body)
        slack_msg = mock_slack.call_args[0][0]
        self.assertIn('post-scan phase stuck', slack_msg)

    @patch.object(main, '_slack_notify')
    @patch('main.compute_v1.InstancesClient')
    def test_no_orphans_found(self, mock_client_cls, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.list.side_effect = [[], [], [], []]

        body, code = main.scavenge_vms(
            _build_request('POST', '/'))
        self.assertEqual(code, 200)
        self.assertIn('Deleted: 0', body)
        mock_slack.assert_not_called()


class TestTriggerProduction(unittest.TestCase):
    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_defaults_when_no_body(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        op = MagicMock()
        client.insert.return_value = op

        body, code, headers = main.trigger_production(
            _build_request('POST', '/', json_body=None))
        result = json.loads(body)

        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'accepted')
        self.assertIn('scan-', result['scan_uuid'])
        self.assertIn('pentest-scan-', result['instance_name'])

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        metadata_dict = {
            item.key: item.value for item in instance.metadata.items
        }
        self.assertEqual(metadata_dict['SCAN_PROFILE'], 'standard')
        self.assertEqual(metadata_dict['TARGET_NAME'], 'AuxScan Production')
        self.assertEqual(metadata_dict['SCAN_MODE'], 'production')
        self.assertEqual(metadata_dict['IMAGE_TAG'], 'production')
        self.assertIn('auxscan.app.data-estate.cloud',
                       metadata_dict['TARGET_URLS'])

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_accepts_reporter_dispatch_params(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        op = MagicMock()
        client.insert.return_value = op

        body, code, headers = main.trigger_production(
            _build_request('POST', '/', json_body={
                'scan_uuid': 'abc-12345-def',
                'profile': 'quick',
                'target_url': 'https://example.com',
                'target_name': 'Example App',
                'callback_url': 'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
                'job_id': 'j1',
                'reporter_base_url': 'https://reporter.example.com',
            }))
        result = json.loads(body)

        self.assertEqual(result['scan_uuid'], 'abc-12345-def')
        self.assertIn('pentest-scan-abc-1234', result['instance_name'])

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        metadata_dict = {
            item.key: item.value for item in instance.metadata.items
        }
        self.assertEqual(metadata_dict['SCAN_PROFILE'], 'quick')
        self.assertEqual(metadata_dict['TARGET_NAME'], 'Example App')
        self.assertEqual(metadata_dict['TARGET_URLS'],
                         json.dumps(['https://example.com']))
        self.assertEqual(metadata_dict['SCAN_UUID'], 'abc-12345-def')
        self.assertEqual(metadata_dict['JOB_ID'], 'j1')
        self.assertEqual(
            metadata_dict['CALLBACK_URL'],
            'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
        )
        self.assertEqual(metadata_dict['REPORTER_BASE_URL'],
                         'https://reporter.example.com')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_wraps_single_url_in_json_array(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body={
                'target_url': 'https://single.example.com',
            }))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        metadata_dict = {
            item.key: item.value for item in instance.metadata.items
        }
        self.assertEqual(metadata_dict['TARGET_URLS'],
                         '["https://single.example.com"]')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_passes_through_json_array_target_urls(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.insert.return_value = MagicMock()

        urls = '["https://a.com", "https://b.com"]'
        main.trigger_production(
            _build_request('POST', '/', json_body={'target_urls': urls}))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        metadata_dict = {
            item.key: item.value for item in instance.metadata.items
        }
        self.assertEqual(metadata_dict['TARGET_URLS'], urls)

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_returns_json_content_type(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.insert.return_value = MagicMock()

        _, _, headers = main.trigger_production(
            _build_request('POST', '/', json_body=None))
        self.assertEqual(headers['Content-Type'], 'application/json')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_labels_include_profile_and_env(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body={
                'profile': 'deep',
                'scan_mode': 'staging',
            }))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        self.assertEqual(instance.labels['env'], 'staging')
        self.assertEqual(instance.labels['profile'], 'deep')


class TestPerEnvironmentFunctions(unittest.TestCase):
    """Per-environment wrappers insulate callers from VM internals."""

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_development_sets_development_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_development(
            _build_request('POST', '/', json_body={'profile': 'quick'}))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'development')
        self.assertEqual(md['IMAGE_TAG'], 'development')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_staging_sets_staging_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_staging(
            _build_request('POST', '/', json_body={'profile': 'standard'}))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'staging')
        self.assertEqual(md['IMAGE_TAG'], 'staging')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_production_sets_production_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body=None))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'production')
        self.assertEqual(md['IMAGE_TAG'], 'production')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_production_uses_spot_pricing(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body=None))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        self.assertEqual(instance.scheduling.provisioning_model, 'SPOT')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_staging_does_not_use_spot_pricing(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_staging(
            _build_request('POST', '/', json_body=None))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        self.assertNotEqual(
            getattr(instance.scheduling, 'provisioning_model', None),
            'SPOT',
        )

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_caller_can_override_scan_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body={'scan_mode': 'staging'}))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'staging')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_profile_passed_through_to_vm(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(
            _build_request('POST', '/', json_body={'profile': 'deep'}))

        instance = client.insert.call_args.kwargs['request']['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_PROFILE'], 'deep')


if __name__ == '__main__':
    unittest.main()
