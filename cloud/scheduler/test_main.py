"""Tests for Cloud Function VM scavenger."""

import json
import os
import subprocess
import unittest
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock, patch, call

os.environ['GCP_PROJECT'] = 'test-project'
os.environ['GCP_REGION'] = 'us-central1'
os.environ['MAX_AGE_MINUTES'] = '30'
os.environ['HARD_MAX_MINUTES'] = '240'

import main  # noqa: E402


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
    def _make_request(self, path='/health'):
        request = MagicMock()
        request.path = path
        return request

    def test_scavenger_health_returns_ok(self):
        body, code, headers = main.scavenge_vms(self._make_request('/health'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')
        self.assertEqual(headers['Content-Type'], 'application/json')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    def test_trigger_health_returns_ok(self):
        body, code, headers = main.trigger_production(self._make_request('/health'))
        result = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'ok')


class TestScavengeVms(unittest.TestCase):
    def _make_instance(self, name, age_minutes):
        created = datetime.now(timezone.utc) - timedelta(minutes=age_minutes)
        inst = MagicMock()
        inst.name = name
        inst.creation_timestamp = created.isoformat()
        return inst

    def _make_request(self):
        request = MagicMock()
        request.path = '/'
        return request

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_skips_young_vms(self, mock_client_cls, mock_check, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        young_vm = self._make_instance('pentest-scan-young', 10)
        client.list.return_value = [young_vm]

        body, code = main.scavenge_vms(self._make_request())
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
        client.list.return_value = [active_vm]
        mock_check.return_value = {
            'alive': True, 'containers': ['pentest-scan-1'],
            'docker_ps': '', 'ssh_failed': False
        }

        body, code = main.scavenge_vms(self._make_request())
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
        client.list.return_value = [idle_vm]
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(self._make_request())
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
        client.list.return_value = [old_vm]
        mock_check.return_value = {
            'alive': True, 'containers': ['pentest-scan-1'],
            'docker_ps': '', 'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(self._make_request())
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
        client.list.return_value = [hung_vm]
        mock_check.return_value = {
            'alive': False, 'containers': [], 'docker_ps': '',
            'ssh_failed': True
        }
        op = MagicMock()
        client.delete.return_value = op

        body, code = main.scavenge_vms(self._make_request())
        self.assertIn('Deleted: 1', body)
        # Slack notification includes SSH unreachable reason
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
        client.list.return_value = [vm]
        mock_check.return_value = {
            'alive': True,
            'containers': ['pentest-scan-20260320 | Up 5 hours | 5h ago'],
            'docker_ps': 'pentest-scan-20260320 | Up 5 hours | 5h ago',
            'ssh_failed': False
        }
        op = MagicMock()
        client.delete.return_value = op

        main.scavenge_vms(self._make_request())
        slack_msg = mock_slack.call_args[0][0]
        self.assertIn('Killed containers', slack_msg)
        self.assertIn('pentest-scan-20260320', slack_msg)

    @patch.object(main, '_slack_notify')
    @patch('main.compute_v1.InstancesClient')
    def test_no_orphans_found(self, mock_client_cls, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.list.return_value = []

        body, code = main.scavenge_vms(self._make_request())
        self.assertEqual(code, 200)
        self.assertIn('Deleted: 0', body)
        mock_slack.assert_not_called()


class TestTriggerProduction(unittest.TestCase):
    def _make_request(self, body=None):
        request = MagicMock()
        request.get_json.return_value = body
        request.path = '/'
        return request

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_defaults_when_no_body(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        op = MagicMock()
        client.insert.return_value = op

        body, code, headers = main.trigger_production(self._make_request(None))
        result = json.loads(body)

        self.assertEqual(code, 200)
        self.assertEqual(result['status'], 'accepted')
        self.assertIn('scan-', result['scan_uuid'])
        self.assertIn('pentest-scan-', result['instance_name'])

        # Verify default metadata values
        instance = client.insert.call_args[1]['instance_resource']
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

        request = self._make_request({
            'scan_uuid': 'abc-12345-def',
            'profile': 'quick',
            'target_url': 'https://example.com',
            'target_name': 'Example App',
            'callback_url': 'https://reporter.example.com/callbacks/scan_complete?job_id=j1',
            'job_id': 'j1',
            'reporter_base_url': 'https://reporter.example.com',
        })

        body, code, headers = main.trigger_production(request)
        result = json.loads(body)

        self.assertEqual(result['scan_uuid'], 'abc-12345-def')
        self.assertIn('pentest-scan-abc-1234', result['instance_name'])

        instance = client.insert.call_args[1]['instance_resource']
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

        request = self._make_request({
            'target_url': 'https://single.example.com',
        })
        main.trigger_production(request)

        instance = client.insert.call_args[1]['instance_resource']
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
        request = self._make_request({'target_urls': urls})
        main.trigger_production(request)

        instance = client.insert.call_args[1]['instance_resource']
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

        _, _, headers = main.trigger_production(self._make_request(None))
        self.assertEqual(headers['Content-Type'], 'application/json')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash\necho hi'))
    @patch('main.compute_v1.InstancesClient')
    def test_labels_include_profile_and_env(self, mock_client_cls):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.insert.return_value = MagicMock()

        request = self._make_request({
            'profile': 'deep',
            'scan_mode': 'staging',
        })
        main.trigger_production(request)

        instance = client.insert.call_args[1]['instance_resource']
        self.assertEqual(instance.labels['env'], 'staging')
        self.assertEqual(instance.labels['profile'], 'deep')


class TestPerEnvironmentFunctions(unittest.TestCase):
    """Per-environment wrappers insulate callers from VM internals."""

    def _make_request(self, body=None):
        request = MagicMock()
        request.get_json.return_value = body
        request.path = '/'
        return request

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_development_sets_development_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_development(self._make_request({'profile': 'quick'}))

        instance = client.insert.call_args[1]['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'development')
        self.assertEqual(md['IMAGE_TAG'], 'development')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_staging_sets_staging_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_staging(self._make_request({'profile': 'standard'}))

        instance = client.insert.call_args[1]['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'staging')
        self.assertEqual(md['IMAGE_TAG'], 'staging')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_trigger_production_sets_production_mode(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(self._make_request(None))

        instance = client.insert.call_args[1]['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'production')
        self.assertEqual(md['IMAGE_TAG'], 'production')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_production_uses_spot_pricing(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_production(self._make_request(None))

        instance = client.insert.call_args[1]['instance_resource']
        self.assertEqual(instance.scheduling.provisioning_model, 'SPOT')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_staging_does_not_use_spot_pricing(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        main.trigger_staging(self._make_request(None))

        instance = client.insert.call_args[1]['instance_resource']
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

        # Caller overrides scan_mode on a production endpoint
        request = self._make_request({'scan_mode': 'staging'})
        main.trigger_production(request)

        instance = client.insert.call_args[1]['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_MODE'], 'staging')

    @patch('builtins.open', unittest.mock.mock_open(read_data='#!/bin/bash'))
    @patch('main.compute_v1.InstancesClient')
    def test_profile_passed_through_to_vm(self, mock_cls):
        client = MagicMock()
        mock_cls.return_value = client
        client.insert.return_value = MagicMock()

        request = self._make_request({'profile': 'deep'})
        main.trigger_production(request)

        instance = client.insert.call_args[1]['instance_resource']
        md = {i.key: i.value for i in instance.metadata.items}
        self.assertEqual(md['SCAN_PROFILE'], 'deep')


if __name__ == '__main__':
    unittest.main()
