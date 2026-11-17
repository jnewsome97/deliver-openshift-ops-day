"""Run production retry/gating directives in real Ansible, with only APIs stubbed.

No cluster, credentials, upstream roles or Kubernetes Python client are needed.
Run: python -m unittest discover -s tests/unit -p 'test_operator_resilience.py' -v
"""
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
ROLES = ROOT / 'automation/ansible/roles'
COMPLIANCE = ROLES / 'ocp4_days_workload_compliance_operator'
METALLB = ROLES / 'ocp4_workload_metallb'

STUB = '''
import json
from pathlib import Path
from ansible.module_utils.basic import AnsibleModule
m = AnsibleModule(argument_spec={
    'kind': {'type': 'str', 'required': True},
    'name': {'type': 'str'},
    'sequence_file': {'type': 'path', 'required': True},
    'state_file': {'type': 'path', 'required': True},
})
p = Path(m.params['state_file'])
s = json.loads(p.read_text()) if p.exists() else {'calls': [], 'counts': {}}
k = m.params['kind']
n = s['counts'].get(k, 0)
s['counts'][k] = n + 1
s['calls'].append({'kind': k, 'name': m.params['name']})
p.write_text(json.dumps(s))
seq = json.loads(Path(m.params['sequence_file']).read_text()).get(k, [{'resources': []}])
r = seq[min(n, len(seq) - 1)]
if r.get('failed'):
    m.fail_json(**{k: v for k, v in r.items() if k != 'failed'})
m.exit_json(changed=False, **r)
'''


def read(path):
    return yaml.safe_load(path.read_text())


def resources(*items):
    return {'resources': list(items)}


def subscription(csv='compliance-operator.v1.10.1'):
    return resources({'metadata': {'name': 'compliance-operator'},
                      'status': {'currentCSV': csv}})


def csv(phase='Succeeded'):
    return resources({'metadata': {'name': 'compliance-operator.v1.10.1'},
                      'status': {'phase': phase}})


def deployment(generation=2, observed=2, ready=1, available=1):
    return resources({'metadata': {'generation': generation}, 'status': {
        'observedGeneration': observed, 'readyReplicas': ready,
        'availableReplicas': available}})


def metallb(status='True'):
    return resources({'status': {'conditions': [{'type': 'Available', 'status': status}]}})


class OperatorResilienceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compliance = read(COMPLIANCE / 'tasks/workload.yml')
        cls.readiness = read(COMPLIANCE / 'tasks/operator_readiness.yml')[0]['block']
        cls.metallb = next(t for t in read(METALLB / 'tasks/workload.yml')
                           if t['name'] == 'Run workload with failure capture')
        cls.defaults = {**read(COMPLIANCE / 'defaults/main.yml'),
                        **read(METALLB / 'defaults/main.yml')}

    def run_tasks(self, tasks, sequences, success=True, extra_vars=None, upstream_task=None):
        with tempfile.TemporaryDirectory(prefix='ops-operator-tests-') as d:
            tmp = Path(d)
            (tmp / 'library').mkdir()
            (tmp / 'library/api_stub.py').write_text(STUB)
            (tmp / 'sequences.json').write_text(json.dumps(sequences))
            collection = tmp / 'collections/ansible_collections/deliver_openshift_ops_day'
            collection.mkdir(parents=True)
            (collection / 'automation').symlink_to(ROOT / 'automation/ansible', target_is_directory=True)
            if upstream_task is not None:
                # Execute a real include_role/rescue with the upstream task's
                # action/name/register shape, not an injected failed-task dict.
                modules = tmp / 'collections/ansible_collections/kubernetes/core/plugins/modules'
                modules.mkdir(parents=True)
                (modules / 'k8s_info.py').write_text(STUB)
                role_tasks = tmp / 'roles/install_operator/tasks'
                role_tasks.mkdir(parents=True)
                task = copy.deepcopy(upstream_task)
                task['kubernetes.core.k8s_info'].update(
                    sequence_file=str(tmp / 'sequences.json'), state_file=str(tmp / 'state.json'))
                (role_tasks / 'main.yml').write_text(yaml.safe_dump([task], sort_keys=False))
            variables = dict(self.defaults)
            # Keep retry counts finite and tests fast; production tasks retain
            # their real until/register/when expressions and variable wiring.
            for key in variables:
                if key.endswith('_retries'):
                    variables[key] = 2
                if key.endswith('_retry_delay'):
                    variables[key] = 0
            variables.update(extra_vars or {})
            variables['ansible_python_interpreter'] = sys.executable

            def stub(task):
                task = copy.deepcopy(task)
                for key in ('kubernetes.core.k8s_info', 'kubernetes.core.k8s'):
                    if key in task:
                        args = task.pop(key)
                        task['api_stub'] = {
                            'kind': args.get('kind', 'Create'),
                            'name': args.get('name'),
                            'sequence_file': str(tmp / 'sequences.json'),
                            'state_file': str(tmp / 'state.json'),
                        }
                includes = {'operator_readiness.yml': COMPLIANCE,
                            'install_compliance.yml': COMPLIANCE,
                            'install_metallb.yml': METALLB}
                filename = task.get('ansible.builtin.include_tasks')
                if filename in includes:
                    # Execute production includes/rescue, never an imitation.
                    included = tmp / filename
                    included.write_text(yaml.safe_dump([
                        stub(t) for t in read(includes[filename] / 'tasks' / filename)
                    ], sort_keys=False))
                    task['ansible.builtin.include_tasks'] = str(included)
                # Model installation invocation only; never run the upstream
                # role in an offline test. Production when/vars are preserved.
                if 'ansible.builtin.include_role' in task and upstream_task is None:
                    task.pop('ansible.builtin.include_role')
                    task['api_stub'] = {
                        'kind': 'Install', 'sequence_file': str(tmp / 'sequences.json'),
                        'state_file': str(tmp / 'state.json')}
                for key in ('block', 'rescue', 'always'):
                    if key in task:
                        task[key] = [stub(t) for t in task[key]]
                return task

            play = [dict(hosts='localhost', connection='local', gather_facts=False,
                         vars=variables, tasks=[stub(t) for t in tasks])]
            (tmp / 'play.yml').write_text(yaml.safe_dump(play, sort_keys=False))
            env = dict(os.environ, ANSIBLE_LIBRARY=str(tmp / 'library'),
                       ANSIBLE_LOCAL_TEMP=str(tmp / 'local'),
                       ANSIBLE_REMOTE_TEMP=str(tmp / 'remote'), ANSIBLE_NOCOLOR='1',
                       ANSIBLE_ROLES_PATH=str(tmp / 'roles'),
                       ANSIBLE_COLLECTIONS_PATH=str(tmp / 'collections'))
            p = subprocess.run([sys.executable, '-m', 'ansible.cli.playbook',
                                '-i', 'localhost,', str(tmp / 'play.yml')], cwd=tmp,
                               env=env, capture_output=True, text=True, timeout=60)
            out = p.stdout + p.stderr
            self.assertEqual(p.returncode == 0, success, out)
            self.assertNotIn('Error while evaluating conditional', out)
            self.assertNotIn('error while evaluating conditional', out)
            state = (json.loads((tmp / 'state.json').read_text())
                     if (tmp / 'state.json').exists() else {'counts': {}, 'calls': []})
            return state, out

    def metal_task(self, name):
        return next(t for t in self.metallb['block'] if t['name'] == name)

    def test_compliance_gates_subscription_csv_and_deployment_in_order(self):
        state, _ = self.run_tasks(self.readiness, {
            'Subscription': [{'failed': True, 'msg': '503'}, resources(), subscription()],
            'ClusterServiceVersion': [resources(), csv('Installing'), csv()],
            'Deployment': [resources(), deployment(observed=1), deployment()],
        })
        self.assertEqual(state['counts'], {
            'Subscription': 3, 'ClusterServiceVersion': 3, 'Deployment': 3})
        self.assertEqual(state['calls'][3]['name'], 'compliance-operator.v1.10.1')

    def test_failed_or_empty_subscription_cannot_reach_csv(self):
        for result in [resources(), {}, resources({}),
                       {'failed': True, **subscription(), 'msg': '500'}]:
            with self.subTest(result=result):
                state, _ = self.run_tasks(self.readiness, {'Subscription': [result]}, False)
                self.assertEqual(state['counts'], {'Subscription': 3})

    def test_missing_or_failed_csv_cannot_reach_deployment(self):
        for result in [resources(), {}, resources({}), csv('Failed'), csv('Installing'),
                       {'failed': True, **csv(), 'msg': '503'}]:
            with self.subTest(result=result):
                state, _ = self.run_tasks(self.readiness, {
                    'Subscription': [subscription()], 'ClusterServiceVersion': [result]}, False)
                self.assertNotIn('Deployment', state['counts'])
                self.assertEqual(state['counts']['ClusterServiceVersion'], 3)

    def test_deployment_requires_fresh_available_replicas(self):
        for result in [resources(), resources({}), deployment(observed=1),
                       deployment(ready=0), deployment(available=0),
                       {'failed': True, **deployment(), 'msg': '503'}]:
            with self.subTest(result=result):
                state, _ = self.run_tasks([self.readiness[-1]], {'Deployment': [result]}, False)
                self.assertEqual(state['counts']['Deployment'], 3)

    def test_existing_subscription_preserves_ownership_and_skips_install(self):
        check = next(t for t in self.compliance if t.get('register') == 'r_existing_subscription')
        install = next(t for t in self.compliance if t['name'] == 'Install Compliance Operator')
        for exists in (True, False):
            with self.subTest(exists=exists):
                state, _ = self.run_tasks([check, install], {
                    'Subscription': [subscription() if exists else resources()],
                })
                self.assertEqual(state['counts'].get('Install', 0), 0 if exists else 1)
        installer = read(COMPLIANCE / 'tasks/install_compliance.yml')[0]['block'][0]
        self.assertIs(installer['vars']['install_operator_install_csv_ignore_error'], False)
        self.assertIn('install_operator_catalogsource_setup', installer['vars'])
        self.assertNotIn('install_operator_use_catalog_snapshot', installer['vars'])

    def test_metallb_readiness_recovers_from_transient_api_and_empty_results(self):
        task = self.metal_task('Wait until MetalLB is installed')
        state, _ = self.run_tasks([task], {'MetalLB': [
            {'failed': True, 'msg': 'webhook unavailable'}, resources(), metallb()]})
        self.assertEqual(state['counts']['MetalLB'], 3)
        self.assertNotIn('wait', task['kubernetes.core.k8s_info'])

    def test_metallb_unhealthy_or_failed_results_exhaust_budget(self):
        for result in [resources(), {}, resources({}), metallb('False'), metallb('Unknown'),
                       resources({'status': {'conditions': [{}]}}),
                       {'failed': True, **metallb(), 'msg': 'webhook down'}]:
            with self.subTest(result=result):
                state, _ = self.run_tasks([self.metal_task('Wait until MetalLB is installed')],
                                          {'MetalLB': [result]}, False)
                self.assertEqual(state['counts']['MetalLB'], 3)

    def test_metallb_catalog_readiness_retries_failed_queries(self):
        task = self.metal_task('Wait for shared redhat-operators-snapshot CatalogSource to be READY')
        ready = resources({'status': {'connectionState': {'lastObservedState': 'READY'}}})
        state, _ = self.run_tasks([task], {'CatalogSource': [
            {'failed': True, **ready, 'msg': '503'}, resources(), ready]},
            extra_vars={'ocp4_workload_metallb_use_catalog_snapshot': True})
        self.assertEqual(state['counts']['CatalogSource'], 3)

    def test_metallb_mutations_retry_without_changing_feature_flags(self):
        for name in ['Create the MetalLB instance', 'Create the IPAddressPool instance',
                     'Create the L2Advertisement instance']:
            task = self.metal_task(name)
            flags = {'ocp4_workload_metallb_enable_ipaddresspool': True,
                     'ocp4_workload_metallb_enable_l2advertisement': True}
            with self.subTest(name=name):
                state, _ = self.run_tasks([task], {'Create': [
                    {'failed': True, 'msg': 'webhook down'}, {}]}, extra_vars=flags)
                self.assertEqual(state['counts']['Create'], 2)
                state, _ = self.run_tasks([task], {'Create': [
                    {'failed': True, 'msg': 'permanent denial'}]}, False, extra_vars=flags)
                self.assertEqual(state['counts']['Create'], 3)

    def test_existing_healthy_installations_need_no_retries(self):
        for _ in range(2):  # Independent reruns; no set_fact cache masks polling.
            state, _ = self.run_tasks(self.readiness, {
                'Subscription': [subscription()], 'ClusterServiceVersion': [csv()],
                'Deployment': [deployment()]})
            self.assertEqual(state['counts'], {
                'Subscription': 1, 'ClusterServiceVersion': 1, 'Deployment': 1})

    def test_full_compliance_flow_preserves_profilebundle_checks(self):
        state, _ = self.run_tasks(self.compliance, {
            'Subscription': [subscription()], 'ClusterServiceVersion': [csv()],
            'Deployment': [deployment()], 'CustomResourceDefinition': [resources({})],
            'ProfileBundle': [resources(
                {'metadata': {'name': 'ocp4'}, 'status': {'dataStreamStatus': 'VALID'}},
                {'metadata': {'name': 'rhcos4'}, 'status': {'dataStreamStatus': 'VALID'}})],
        })
        self.assertNotIn('Install', state['counts'])
        self.assertEqual(state['counts']['ProfileBundle'], 1)
        self.assertEqual(state['counts']['Pod'], 1)

    def test_compliance_rescue_remains_fatal_and_respects_no_log(self):
        block = copy.deepcopy(read(COMPLIANCE / 'tasks/operator_readiness.yml')[0])
        block['block'][0]['no_log'] = True
        secret = 'DO_NOT_PRINT_FAILURE_PAYLOAD'
        state, out = self.run_tasks([block], {'Subscription': [
            {'failed': True, 'msg': 'API unavailable', 'sensitive_details': secret}]}, False)
        self.assertNotIn(secret, out)
        self.assertIn('a task with no_log enabled', out)
        self.assertIn('No approval policy was changed', out)
        self.assertEqual(state['counts']['InstallPlan'], 1)

    def test_compliance_diagnostics_only_print_allowlisted_state(self):
        block = copy.deepcopy(read(COMPLIANCE / 'tasks/operator_readiness.yml')[0])
        block['block'][0]['no_log'] = True
        pending = resources({
            'metadata': {'name': 'compliance-operator',
                         'annotations': {'private': 'DO_NOT_PRINT_ANNOTATION'}},
            'spec': {'installPlanApproval': 'Manual'},
            'status': {'conditions': [{'type': 'ResolutionFailed', 'status': 'True',
                                      'reason': 'ConstraintsNotSatisfiable',
                                      'message': 'DO_NOT_PRINT_RAW_CONDITION'}]}})
        state, out = self.run_tasks([block], {'Subscription': [pending]}, False)
        self.assertIn('ConstraintsNotSatisfiable', out)
        self.assertIn('Manual', out)
        self.assertNotIn('DO_NOT_PRINT_ANNOTATION', out)
        self.assertNotIn('DO_NOT_PRINT_RAW_CONDITION', out)
        self.assertNotIn('Install', state['counts'])

    def test_metallb_rescue_remains_fatal_and_respects_no_log(self):
        fail_task = copy.deepcopy(self.metal_task('Create the MetalLB instance'))
        fail_task['no_log'] = True
        # Keep the real terminal failure; existing shell-based cluster
        # diagnostics cannot run in this cluster-free test.
        terminal = self.metallb['rescue'][-1]
        state, out = self.run_tasks([{'block': [fail_task], 'rescue': [terminal]}],
                                   {'Create': [{'failed': True, 'msg': 'API unavailable',
                                                'sensitive_details': 'DO_NOT_PRINT_PAYLOAD'}]}, False)
        self.assertEqual(state['counts']['Create'], 3)
        self.assertNotIn('DO_NOT_PRINT_PAYLOAD', out)
        self.assertIn('a task with no_log enabled', out)

    def test_metallb_optional_resources_remain_disabled_by_default(self):
        tasks = [self.metal_task('Create the MetalLB instance'),
                 self.metal_task('Create the IPAddressPool instance'),
                 self.metal_task('Create the L2Advertisement instance')]
        state, _ = self.run_tasks(tasks, {'Create': [{}]})
        self.assertEqual(state['counts']['Create'], 1)

    def test_profilebundles_still_require_two_valid_bundles(self):
        task = next(t for t in self.compliance if t['name'] == 'Wait for ProfileBundles to be parsed')
        invalid = resources({'status': {'dataStreamStatus': 'INVALID'}}, {})
        state, _ = self.run_tasks([task], {'ProfileBundle': [invalid]}, False)
        self.assertEqual(state['counts']['ProfileBundle'], 3)

    def test_slow_installer_csv_gets_bounded_local_grace_in_both_roles(self):
        upstream = {'name': 'Wait until CSV is installed ({{ install_operator_name }})',
                    'kubernetes.core.k8s_info': {'kind': 'ClusterServiceVersion'},
                    'register': 'r_csv'}
        for rolefile in ['install_compliance.yml', 'install_metallb.yml']:
            with self.subTest(rolefile=rolefile):
                tasks = [{'ansible.builtin.include_tasks': rolefile}]
                if rolefile == 'install_compliance.yml':
                    tasks += self.readiness
                state, out = self.run_tasks(tasks, {
                    'ClusterServiceVersion': [{'failed': True, 'msg': 'CSV wait exhausted'}, csv()],
                    'Subscription': [subscription()], 'Deployment': [deployment()],
                }, upstream_task=upstream)
                self.assertEqual(state['counts']['ClusterServiceVersion'], 2)
                self.assertIn('finite', out)

    def test_installer_grace_rejects_configuration_and_permission_failures(self):
        for rolefile in ['install_compliance.yml', 'install_metallb.yml']:
            for name, message, status in [
                ('Create operator subscription', 'invalid configuration', 0),
                ('Wait until CSV is installed', 'Forbidden', 0),
                ('Wait until CSV is installed', 'access denied', 403),
                ('Wait until CSV is installed', 'Unauthorized', 401),
            ]:
                upstream = {'name': name, 'kubernetes.core.k8s_info': {
                    'kind': 'ClusterServiceVersion'}, 'register': 'r_csv'}
                with self.subTest(rolefile=rolefile, name=name, status=status):
                    state, _ = self.run_tasks([{'ansible.builtin.include_tasks': rolefile}], {
                        'ClusterServiceVersion': [{'failed': True, 'msg': message, 'status': status}],
                    }, False, upstream_task=upstream)
                    self.assertNotIn('Subscription', state['counts'])
                    self.assertEqual(state['counts']['ClusterServiceVersion'], 1)

    def test_grace_never_turns_persistent_csv_failure_into_success(self):
        upstream = {'name': 'Wait until CSV is installed',
                    'kubernetes.core.k8s_info': {'kind': 'ClusterServiceVersion'},
                    'register': 'r_csv'}
        for rolefile in ['install_compliance.yml', 'install_metallb.yml']:
            with self.subTest(rolefile=rolefile):
                tasks = [{'ansible.builtin.include_tasks': rolefile}]
                if rolefile == 'install_compliance.yml':
                    tasks += self.readiness
                state, _ = self.run_tasks(tasks, {
                    'ClusterServiceVersion': [{'failed': True, 'msg': 'CSV timeout'}, csv('Failed')],
                    'Subscription': [subscription()],
                }, False, upstream_task=upstream)
                self.assertEqual(state['counts']['ClusterServiceVersion'], 4)
                self.assertNotIn('Deployment', state['counts'])

    def test_metallb_csv_gate_precedes_resource_creation(self):
        tasks = [{'ansible.builtin.include_tasks': 'install_metallb.yml'},
                 self.metal_task('Create the MetalLB instance')]
        state, _ = self.run_tasks(tasks, {
            'Subscription': [subscription()], 'ClusterServiceVersion': [csv('Failed')],
        }, False)
        self.assertNotIn('Create', state['counts'])

    def test_subscription_failure_cannot_be_hidden_by_an_old_current_csv(self):
        metal_gate = read(METALLB / 'tasks/install_metallb.yml')[1]
        for gate in [self.readiness[0], metal_gate]:
            for kind in ['ResolutionFailed', 'InstallPlanFailed']:
                failed = subscription()
                failed['resources'][0]['status']['conditions'] = [{'type': kind, 'status': 'True'}]
                with self.subTest(gate=gate['name'], kind=kind):
                    state, _ = self.run_tasks([gate], {'Subscription': [failed]}, False)
                    self.assertEqual(state['counts']['Subscription'], 3)

    def test_subscription_resolution_can_recover_without_reinstallation(self):
        failed = subscription()
        failed['resources'][0]['status']['conditions'] = [
            {'type': 'ResolutionFailed', 'status': 'True'}]
        for gate in [self.readiness[0], read(METALLB / 'tasks/install_metallb.yml')[1]]:
            with self.subTest(gate=gate['name']):
                state, _ = self.run_tasks([gate], {'Subscription': [failed, subscription()]})
                self.assertEqual(state['counts']['Subscription'], 2)
                self.assertNotIn('Install', state['counts'])

    def test_default_budgets_and_no_suppressed_readiness_failures(self):
        self.assertEqual(self.defaults['ocp4_workload_metallb_catalog_wait_retries'], 120)
        self.assertEqual(self.defaults['ocp4_workload_metallb_install_retries'], 120)
        self.assertEqual(self.defaults['ocp4_workload_metallb_readiness_retries'], 120)
        self.assertEqual(self.defaults['ocp4_days_workload_compliance_operator_readiness_retries'], 120)
        self.assertEqual(self.defaults['ocp4_days_workload_compliance_operator_install_retries'], 120)
        for task in self.readiness:
            self.assertNotIn('ignore_errors', task)
            self.assertNotIn('failed_when', task)


if __name__ == '__main__':
    unittest.main()
