"""Run the production OLS e2e readiness task against a strict offline API stub."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
OLS = ROOT / 'qa-automation/tasks/e2e/ols.yml'
DEPLOYMENTS = {
    'lightspeed-agentic-alerts-adapter', 'lightspeed-agentic-console-plugin',
    'lightspeed-agentic-operator-controller-manager', 'lightspeed-app-server',
    'lightspeed-console-plugin', 'lightspeed-operator-controller-manager',
    'lightspeed-otel-collector', 'lightspeed-postgres-server', 'lightspeed-rhokp',
    'openshift-mcp-server',
}

STUB = '''
from ansible.module_utils.basic import AnsibleModule
from pathlib import Path
import json
m = AnsibleModule(argument_spec={
    'api_version': {'type': 'str'}, 'kind': {'type': 'str'},
    'name': {'type': 'str'}, 'namespace': {'type': 'str'},
    'test_config': {'type': 'path'},
})
c = json.loads(Path(m.params['test_config']).read_text())
p = Path(c['state'])
s = json.loads(p.read_text()) if p.exists() else {}
name = m.params['name']; n = s.get(name, 0); s[name] = n + 1
p.write_text(json.dumps(s))
if name not in c['deployments']:
    m.exit_json(changed=False, resources=[])
sequence = c['sequence']
r = sequence[min(n, len(sequence) - 1)]
if r.get('failed'):
    m.fail_json(**{k: v for k, v in r.items() if k != 'failed'})
m.exit_json(changed=False, **r)
'''


def ready():
    return {'resources': [{'metadata': {'generation': 2}, 'spec': {'replicas': 1},
                           'status': {'observedGeneration': 2, 'readyReplicas': 1,
                                      'availableReplicas': 1}}]}


class OlsE2EDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tasks = yaml.safe_load(OLS.read_text())
        cls.task = next(t for t in cls.tasks if t.get('register') == 'hc_ols_e2e_deploy')

    def run_task(self, sequence, success=True, all_names=False, old_name=False):
        with tempfile.TemporaryDirectory(prefix='ols-e2e-readiness-') as d:
            tmp = Path(d)
            (tmp / 'library').mkdir()
            (tmp / 'library/api_stub.py').write_text(STUB)
            (tmp / 'config.json').write_text(json.dumps({
                'state': str(tmp / 'state.json'), 'sequence': sequence,
                'deployments': sorted(DEPLOYMENTS)}))
            task = copy.deepcopy(self.task)
            task['api_stub'] = task.pop('kubernetes.core.k8s_info')
            task['api_stub']['test_config'] = str(tmp / 'config.json')
            if not all_names:
                task['loop'] = ['lightspeed-agentic-operator' if old_name else
                                'lightspeed-agentic-operator-controller-manager']
            play = [dict(hosts='localhost', connection='local', gather_facts=False,
                         vars={'qa_ols_deployment_retries': 2, 'qa_ols_deployment_delay': 0,
                               'ansible_python_interpreter': sys.executable}, tasks=[task])]
            (tmp / 'play.yml').write_text(yaml.safe_dump(play, sort_keys=False))
            env = dict(os.environ, ANSIBLE_LIBRARY=str(tmp / 'library'),
                       ANSIBLE_LOCAL_TEMP=str(tmp / 'local'),
                       ANSIBLE_REMOTE_TEMP=str(tmp / 'remote'), ANSIBLE_NOCOLOR='1')
            r = subprocess.run([sys.executable, '-m', 'ansible.cli.playbook',
                                '-i', 'localhost,', str(tmp / 'play.yml')], cwd=tmp,
                               env=env, capture_output=True, text=True, timeout=60)
            out = r.stdout + r.stderr
            self.assertEqual(r.returncode == 0, success, out)
            self.assertNotIn('Error while evaluating conditional', out)
            return json.loads((tmp / 'state.json').read_text())

    def test_all_ten_real_ols_201_deployments_are_checked(self):
        self.assertEqual(set(self.task['loop']), DEPLOYMENTS)
        self.assertEqual(len(self.task['loop']), 10)
        calls = self.run_task([ready()], all_names=True)
        self.assertEqual(calls, {name: 1 for name in DEPLOYMENTS})

    def test_original_wrong_name_is_rejected_even_when_others_are_healthy(self):
        calls = self.run_task([ready()], success=False, old_name=True)
        self.assertEqual(calls, {'lightspeed-agentic-operator': 3})

    def test_transient_failed_query_and_absent_resource_can_recover(self):
        stale = ready()
        stale.update(failed=True, msg='500 API unavailable')
        calls = self.run_task([stale, {'resources': []}, ready()])
        self.assertEqual(next(iter(calls.values())), 3)
        self.assertNotIn('failed_when', self.task)

    def test_missing_or_unavailable_deployments_still_fail_with_finite_budget(self):
        stale = ready()
        stale['resources'][0]['status']['observedGeneration'] = 1
        unavailable = ready()
        unavailable['resources'][0]['status']['availableReplicas'] = 0
        for response in [{}, {'resources': []}, {'resources': [{}]}, stale, unavailable,
                         {'failed': True, 'msg': 'persistent API error'}]:
            with self.subTest(response=response):
                calls = self.run_task([response], success=False)
                self.assertEqual(next(iter(calls.values())), 3)

    def test_scaled_down_operator_does_not_pass_readiness(self):
        response = ready()
        response['resources'][0]['spec']['replicas'] = 0
        calls = self.run_task([response], success=False)
        self.assertEqual(next(iter(calls.values())), 3)

    def test_auth_tokens_and_credential_requests_are_not_logged(self):
        def walk(tasks):
            for t in tasks:
                yield t
                for key in ('block', 'rescue', 'always'):
                    yield from walk(t.get(key, []))
        sensitive = {'hc_ols_e2e_secret', 'hc_ols_e2e_token', 'hc_ols_e2e_query',
                     'hc_ols_e2e_maas_secret', 'hc_ols_e2e_maas'}
        found = set()
        for task in walk(self.tasks):
            if task.get('register') in sensitive:
                self.assertIs(task.get('no_log'), True)
                found.add(task['register'])
        self.assertEqual(found, sensitive)


if __name__ == '__main__':
    unittest.main()
