"""Execute bounded download and missing/present ESO API cleanup regressions."""
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest
import yaml

import test_operator_resilience as harness_module

ROOT = Path(__file__).resolve().parents[2]


def walk(tasks):
    for task in tasks:
        yield task
        for key in ('block', 'rescue', 'always'):
            yield from walk(task.get(key, []))


class VaultE2EBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        harness_module.OperatorResilienceTests.setUpClass()
        cls.harness = harness_module.OperatorResilienceTests(
            'test_default_budgets_and_no_suppressed_readiness_failures')
        cls.tasks = yaml.safe_load((ROOT / 'qa-automation/tasks/e2e/vault.yml').read_text())
        cls.eso = next(t for t in cls.tasks if t['name'] ==
                       'Vault | Deploy, validate, and clean up ESO sync pattern')
        cls.download = next(t for t in walk(cls.tasks) if 'ansible.builtin.get_url' in t)

    def test_pinned_verified_download_extraction_and_private_helm_config(self):
        args = self.download['ansible.builtin.get_url']
        self.assertEqual(args['url'], 'https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz')
        self.assertEqual(args['checksum'],
                         'sha256:fc307327959aa38ed8f9f7e66d45492bb022a66c3e5da6063958254b9767d179')
        self.assertTrue(args.get('validate_certs', True))
        self.assertIn('default(6)', self.download['retries'])
        self.assertNotIn('ignore_errors', self.download)
        extract = next(t for t in walk(self.tasks) if 'ansible.builtin.unarchive' in t)
        self.assertEqual(extract['ansible.builtin.unarchive']['src'], args['dest'])
        for value in self.eso['environment'].values():
            self.assertTrue(value.startswith('/tmp/qa-e2e-helm/'))
        for name in ['Vault | Add external-secrets Helm repo', 'Vault | Update external-secrets Helm repo']:
            task = next(t for t in walk(self.tasks) if t.get('name') == name)
            self.assertIn('until', task)
            self.assertNotIn('ignore_errors', task)

    def download_fixture(self, failures, success, bad_checksum=False, reset=False):
        body = b'checksum-verified fixture, not an executable\n'
        counts = {'requests': 0}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                counts['requests'] += 1
                if counts['requests'] <= failures:
                    if reset:
                        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                        self.connection.close()
                        self.close_connection = True
                        return
                    self.send_error(503, 'Temporary fixture outage')
                else:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='vault-download-test-') as directory:
                dest = Path(directory) / 'helm.tar.gz'
                task = copy.deepcopy(self.download)
                task['retries'] = 2
                task['delay'] = 0
                task['ansible.builtin.get_url'].update({
                    'url': f'http://127.0.0.1:{server.server_port}/helm.tar.gz',
                    'dest': str(dest), 'use_proxy': False,
                    'checksum': 'sha256:' + ('0' * 64 if bad_checksum else hashlib.sha256(body).hexdigest())})
                self.harness.run_tasks([task], {}, success)
                if success:
                    self.assertEqual(dest.read_bytes(), body)
                else:
                    self.assertFalse(dest.exists(), 'Do not retain an unverified/partial download')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.assertEqual(counts['requests'], 3)

    def test_download_recovers_from_two_transient_failures(self):
        self.download_fixture(failures=2, success=True)

    def test_download_recovers_from_connection_resets(self):
        self.download_fixture(failures=2, success=True, reset=True)

    def test_persistent_download_failure_is_fatal_and_finite(self):
        self.download_fixture(failures=999, success=False)

    def test_wrong_checksum_is_never_accepted(self):
        self.download_fixture(failures=0, success=False, bad_checksum=True)

    def cleanup(self):
        tasks = copy.deepcopy(self.eso['always'])
        for task in tasks:
            task['retries'] = 2
            task['delay'] = 0
            if 'ansible.builtin.command' in task:
                task.pop('ansible.builtin.command')
                task['ansible.builtin.debug'] = {'msg': 'Reached QA Vault KV cleanup'}
        return tasks

    def test_cleanup_skips_only_absent_custom_apis_and_still_removes_core_secrets(self):
        state, out = self.harness.run_tasks(self.cleanup(), {
            'CustomResourceDefinition': [{'resources': []}], 'Secret': [{}]})
        self.assertEqual(state['counts']['CustomResourceDefinition'], 2)
        self.assertNotIn('ExternalSecret', state['counts'])
        self.assertNotIn('SecretStore', state['counts'])
        self.assertEqual(state['counts']['Secret'], 2)
        self.assertIn('Reached QA Vault KV cleanup', out)

    def test_existing_apis_preserve_finalizer_first_cleanup(self):
        exists = {'resources': [{'metadata': {'name': 'fixture-crd'}}]}
        deleting = {'resources': [{'metadata': {'name': 'qa-e2e-sync-secret',
                                                'finalizers': ['fixture/finalizer']}}]}
        state, _ = self.harness.run_tasks(self.cleanup(), {
            'CustomResourceDefinition': [exists],
            'ExternalSecret': [deleting, deleting, {'resources': []}],
            'SecretStore': [{}], 'Secret': [{}]})
        self.assertEqual(state['counts']['ExternalSecret'], 3)
        self.assertEqual(state['counts']['SecretStore'], 1)
        self.assertEqual(state['counts']['Secret'], 2)

    def test_discovery_failure_cannot_be_treated_as_missing_api(self):
        state, _ = self.harness.run_tasks(self.cleanup(), {
            'CustomResourceDefinition': [{'failed': True, 'msg': 'Forbidden'}]}, False)
        self.assertEqual(state['counts']['CustomResourceDefinition'], 3)
        self.assertNotIn('Secret', state['counts'])

    def test_stuck_finalizer_keeps_provider_credentials_and_fails(self):
        state, _ = self.harness.run_tasks(self.cleanup(), {
            'CustomResourceDefinition': [{'resources': [{}]}],
            'ExternalSecret': [{'resources': [{'metadata': {'finalizers': ['fixture/finalizer']}}]}]}, False)
        self.assertEqual(state['counts']['ExternalSecret'], 4)
        self.assertNotIn('SecretStore', state['counts'])
        self.assertNotIn('Secret', state['counts'])


if __name__ == '__main__':
    unittest.main()
