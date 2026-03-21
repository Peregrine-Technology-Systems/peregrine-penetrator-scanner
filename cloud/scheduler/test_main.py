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


class TestScavengeVms(unittest.TestCase):
    def _make_instance(self, name, age_minutes):
        created = datetime.now(timezone.utc) - timedelta(minutes=age_minutes)
        inst = MagicMock()
        inst.name = name
        inst.creation_timestamp = created.isoformat()
        return inst

    @patch.object(main, '_slack_notify')
    @patch.object(main, '_check_vm_status')
    @patch('main.compute_v1.InstancesClient')
    def test_skips_young_vms(self, mock_client_cls, mock_check, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        young_vm = self._make_instance('pentest-scan-young', 10)
        client.list.return_value = [young_vm]

        body, code = main.scavenge_vms(None)
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

        body, code = main.scavenge_vms(None)
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

        body, code = main.scavenge_vms(None)
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

        body, code = main.scavenge_vms(None)
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

        body, code = main.scavenge_vms(None)
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

        main.scavenge_vms(None)
        slack_msg = mock_slack.call_args[0][0]
        self.assertIn('Killed containers', slack_msg)
        self.assertIn('pentest-scan-20260320', slack_msg)

    @patch.object(main, '_slack_notify')
    @patch('main.compute_v1.InstancesClient')
    def test_no_orphans_found(self, mock_client_cls, mock_slack):
        client = MagicMock()
        mock_client_cls.return_value = client
        client.list.return_value = []

        body, code = main.scavenge_vms(None)
        self.assertEqual(code, 200)
        self.assertIn('Deleted: 0', body)
        mock_slack.assert_not_called()


if __name__ == '__main__':
    unittest.main()
