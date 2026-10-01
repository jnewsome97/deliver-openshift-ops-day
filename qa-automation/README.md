# qa-automation

## healthcheck.yml

Post-provision readiness check (< 60s). Confirms the base environment is
functional (monorepo cloned, logged in to the cluster, Showroom pod running,
operator Subscriptions present), then runs module-specific checks.

This lab has a module selector (`module_enable_*` catalog parameters, see
`rh1-2027/lb1543-ocp-ops-day-cnv/common.yaml`), so not every claim deploys the
same workloads. Module checks live under `tasks/` and are only run when their
module was enabled for this claim — read from the `MODULE_ENABLE_*` env vars
common.yaml sets on the Showroom pod. A disabled module is skipped, not
treated as a failure.

| Module (`module_enable_*`) | Task file | Checks |
|---|---|---|
| `virt` | `tasks/virt.yml` | HyperConverged `kubevirt-hyperconverged` Available |
| `gitops` | `tasks/gitops.yml` | ArgoCD `openshift-gitops` exists |
| `devhub` | `tasks/devhub.yml` | Backstage deployment ready in `backstage`; `pre-built-catalog` ConfigMap has actual catalog data; the four RHDH workshop team namespaces exist and are Active |
| `security` | `tasks/security.yml` | RHACS `central` ready; compliance-operator CSV Succeeded; both ProfileBundles (`ocp4`, `rhcos4`) VALID; Central route patched to `reencrypt` (required for the Showroom iframe embed) |
| `ols` | `tasks/ols.yml` | `OLSConfig/cluster` exists; `lightspeed-app-server` Deployment has `readyReplicas >= 1` (matches the exact condition `ocp4_workload_ols_cleanup` itself waits on) |
| `acm` | `tasks/acm.yml` | `MultiClusterHub` phase `Running`; `MultiClusterObservability` condition `Ready`; `observer-bucket` ConfigMap has a populated `BUCKET_NAME`; `managed-hcp` HostedCluster (HyperShift-on-KubeVirt) condition `Available`; `rhel9` VM boot source `DataSource` condition `Ready` (Module 11 dependency, provisioned by the same `_hcp_workloads` bundle even though it's virt content) |
| `ztwim` | `tasks/ztwim.yml` | ZTWIM operator deployment ready |
| `vault` | `tasks/vault.yml` | `vault` namespace is `Active` (not missing/stuck `Terminating`); Vault server pod Running and ready |

The other `module_enable_*` parameters (`install`, `appmgmt`, `ingress`,
`netsec`, `debugging`, `ldap`, `oidc`, `observability`, `performance`) only
gate Showroom content, not a distinct workload deployment, so they have no
corresponding task file here.

**Provisioning bundles don't match the module flags 1:1** — a few of
`common.yaml`'s workload groups are triggered by a different flag (or an OR
of several) than the task file's own name suggests, so the `when:` gates in
`healthcheck.yml` deliberately don't just mirror `module_enable_<name>`:

- `module_enable_security`, `_ztwim`, and `_vault` all gate the *same*
  `_security_workloads` list (RHACS + console-embed + compliance-operator +
  ZTWIM + Vault) as one bundle — enabling any one of the three deploys all
  five. `security.yml`, `ztwim.yml`, and `vault.yml` are each gated on
  `module_enable_security or module_enable_ztwim or module_enable_vault`,
  not their own individual flag, so a vault-only claim still gets
  RHACS/compliance-operator/ZTWIM checked too.
- `module_enable_acm` alone also triggers `_hcp_workloads`, which deploys
  OpenShift Virtualization and GitOps as HCP/KubeVirt infrastructure —
  independent of `module_enable_virt`/`_gitops`. `virt.yml` and `gitops.yml`
  are gated on `module_enable_virt or module_enable_acm` and
  `module_enable_gitops or module_enable_acm` respectively.

Getting this wrong doesn't cause false failures — it causes false *passes*
(a check silently skipped for a workload that was actually deployed), which
is worse, since it looks like the module isn't part of this claim instead of
looking broken.

All checks are read-only (`kubernetes.core.k8s_info`, `stat`, `oc whoami`) —
this playbook only verifies the environment is set up correctly, it never
creates, patches, or deletes cluster resources.

Every check is collected instead of failing fast: `hc_failures` accumulates
every problem found, and a single run reports all of them at once instead of
stopping at the first one. With eight independently-toggleable modules,
knowing everything that's broken in one pass matters more than in a
fixed-stack workshop.

Exit 0 = healthy, non-zero = unhealthy (message lists every failure found).

## e2e.yml

Full end-to-end run of each module's solve + validate sequence. Unlike
`healthcheck.yml`, this is **not** read-only — task files under `tasks/e2e/`
create and clean up real resources (e.g. Module 1's `qa-e2e-quick-demo`
project with an httpd deployment) to simulate what a learner would actually
do.

**Isolation from live learner sessions:** module lab pages have learners run
some of these same exercises themselves, often with the exact resource names
shown in the page (e.g. index.adoc's "Deploy and Expose in 30 Seconds" uses
project `quick-demo`, app `hello`). Task files under `tasks/e2e/` must use
their own dedicated names (the `qa-e2e-` prefix on `tasks/e2e/overview.yml`'s
project, for example) so an e2e run can never collide with — or delete — a
real learner's in-progress work on the same claim. Keep this in mind when
authoring e2e content for the remaining modules.

It uses the same module-aware structure as `healthcheck.yml`: the same
`MODULE_ENABLE_*` env vars are read into `module_enable_*` vars, and each
module's sequence lives in its own `tasks/e2e/<module>.yml`, included only
when that module is enabled for the claim, with the same bundling gates as
`healthcheck.yml` (`security`/`ztwim`/`vault` share one OR gate; `virt`/
`gitops` are also gated on `module_enable_acm`).

Module 1 (Overview, `tasks/e2e/overview.yml`) is base content shown on every
claim regardless of module selection, so it always runs unconditionally.

| Module (`module_enable_*`) | Task file | Solve/validate flow |
|---|---|---|
| `virt` | `tasks/e2e/virt.yml` | Creates a VM cloning the `rhel9` boot source, waits for the VMI to reach `Running`, confirms the backing `virt-launcher` pod is `Running`. Live migration/clone/snapshot skipped (slow disk I/O, no extra pass/fail signal). |
| `gitops` | `tasks/e2e/gitops.yml` | Deploys an AppProject/Application from the lab's own Git bundle with self-heal enabled, confirms Synced/Healthy and the bundle resources landed, drifts a ResourceQuota, confirms self-heal reverts it. Skips entirely if the bundle's hardcoded `gitops-managed-project` namespace already exists (assumes a live learner is using it — see note below). |
| `devhub` | `tasks/e2e/devhub.yml` | Runs the module's own read-only config-tracing commands (Backstage CR references, dynamic-plugins/app-config ConfigMaps, RHDH ClusterRoleBindings), then a self-contained label-mismatch-and-fix check mirroring the module's Ticket 1 diagnosis, in an isolated namespace. Skips the shared ticket-exercise namespaces/deployments and the shared Backstage CR's monitoring toggle (real learner resources, not isolatable). |
| `security` | `tasks/e2e/security.yml` | Deploys a deliberately vulnerable workload (OWASP Juice Shop) in an isolated namespace and confirms it comes up, giving RHACS something to scan. Skips the cluster-wide `allowedRegistries` patch and the cluster-wide `KILL_POD_ENFORCEMENT` policy (both affect the whole cluster, not just a test namespace) and RHACS-side violation confirmation (no confirmed headless Central API credentials). |
| `ols` | `tasks/e2e/ols.yml` | Execs into the `lightspeed-app-server` pod and asks its `/v1/query` API a real question, asserts a 200 with a real RAG-grounded answer. No resources created. Leaves the module's own `lightspeed-demo`/broken-pod troubleshooting fixture untouched (a live learner's exercise). |
| `acm` | `tasks/e2e/acm.yml` | Applies a GDPR-style Policy/Placement/PlacementBinding, confirms RHACM actually propagates and enforces it (targets `local-cluster`, since `managed-hcp`'s governance addons are `unreachable` on this environment). Skips the console-driven hosted-cluster-creation/VM-wizard/ApplicationSet flow. |
| `vault` | `tasks/e2e/vault.yml` | Configures Vault Kubernetes auth + KV v2 (idempotent), writes a secret, validates both the Agent Injector pattern (file injected into a pod) and the External Secrets Operator pattern (synced `Secret` with correct values) end to end. Cleanup deletes the `ExternalSecret` first and confirms its finalizer clears before removing anything else — the exact ordering the live cluster's stuck-`Terminating` `vault` namespace was missing. |

Every `tasks/e2e/<module>.yml` that creates real cluster resources uses
`qa-e2e-`-prefixed names, deliberately different from every literal name the
module's own lab page tells a learner to type, and wraps creation/validation
in an ansible `block`/`always` so a failed assertion still cleans up instead
of stranding resources on the cluster. Where a module's real exercise
resource names aren't parameterizable (e.g. `gitops`'s Git-bundled manifests,
`ztwim`'s external setup scripts), the e2e sequence either skips entirely if
the real learner resource already exists, or validates a safe, isolatable
subset of the same mechanism instead of reproducing the exercise verbatim.

`acm.yml` accumulates into the `hc_failures` list `e2e.yml` reports at the
end (same pattern as `healthcheck.yml`); the other module files fail fast via
`failed_when`, matching `tasks/e2e/overview.yml`'s existing style.

There is intentionally no `tasks/e2e/ztwim.yml`. The module's own lab page
(`module-17-ztwim.adoc`) only expects the ZTWIM operator to be pre-installed;
the SPIRE server/agents, CSI driver, and OIDC discovery endpoint (and with
them, the SPIFFE/SPIRE admission webhook) are created by the learner running
`configure-ztwim-lab.sh` during the lab itself, not by provisioning. So
`healthcheck.yml`'s `tasks/ztwim.yml` (operator Deployment ready) is the
correct and complete pre-lab check; asserting the webhook exists at e2e time
would be asserting state the module deliberately defers to the learner.

## Run

```bash
# From the repo root, kubeconfig already selected for the claim:
ansible-playbook qa-automation/healthcheck.yml
ansible-playbook qa-automation/e2e.yml

ansible-playbook --syntax-check qa-automation/healthcheck.yml
ansible-playbook --syntax-check qa-automation/e2e.yml
```

Requires `oc` on PATH and access to the runtime-automation kubeconfig (or
pass one directly via `-e k8s_kubeconfig=<path>`).
