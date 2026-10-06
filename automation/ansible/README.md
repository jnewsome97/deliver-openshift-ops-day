# OpenShift Days: Ops Track Collection

Ansible collection for deploying the OpenShift Days Ops Track Workshop on CNV multi-cluster environments.

Deployed via agnosticv catalog item `agd_v2/openshift-days-ops-track-cnv`. The workshop connects to a pre-existing OCP cluster from a CNV pool and installs all workloads on top.

## Roles

### Workshop Core
- `ocp4_workload_days_ops_track` - Main workshop setup: cluster metadata, Showroom configuration (injects variables, rebuilds Antora site), NooBaa/BackingStore resource reduction, OLS demo pod, optional LVMS deployment
- `ocp4_workload_cluster_diagnostics` - End-of-deployment diagnostics: nodes, operators, storage, pods, events, HCP status. Runs last, all tasks use `ignore_errors` so failures never block deployment
- `ocp4_workload_kubernetes_image_puller` - Pre-pulls container images to worker nodes so exercises don't wait for image pulls

### RHACS (Advanced Cluster Security)
- `ocp4_workload_rhacs` - Original ops_track copy with hardcoded resource reductions (deprecated, kept for reference)
- `ocp4_workload_rhacs_v2` - Variable-driven version with optional resource overrides. Behaves identically to the upstream `core_workloads` role when no overrides are set. Upstream PR pending: https://github.com/agnosticd/core_workloads/pull/76

### Quay (Container Registry)
- `ocp4_workload_quay_operator` - Original ops_track copy with hardcoded resource reductions (deprecated, kept for reference)
- `ocp4_workload_quay_operator_v2` - Variable-driven version with optional resource/replica overrides and startup probe patch. Behaves identically to the upstream `core_workloads` role when no overrides are set. Upstream PR pending: https://github.com/agnosticd/core_workloads/pull/76

> **Note:** The v2 roles exist temporarily while the upstream core_workloads PR is under review. Once merged, the v2 copies and the original ops_track copies will be removed and the workshop will use the upstream roles directly with override variables set in agnosticv.

### Multi-Cluster & ACM
- `ocp4_workload_rhacm_cloud_credentials` - Creates KubeVirt provider credentials in ACM and installs the hcp CLI, enabling ACM to provision HCP clusters on the local CNV infrastructure
- `ocp4_workload_acm_multicluster_observability` - ACM MultiCluster Observability with Thanos-based metrics. Supports compact resource mode for resource-constrained clusters
- `ocp4_workload_hcp_kubevirt` - Patches the default IngressController to accept wildcard routes (required for HCP cluster API/console access)
- `ocp4_workload_create_hcp_cluster` - Provisions a managed HCP cluster on KubeVirt so the ACM module has a real multi-cluster environment

### Day 2 Operations
- `ocp4_days_workload_compliance_operator` - Installs the Compliance Operator for CIS/NIST scanning in the security module
- `ocp4_workload_oadp` - Installs OADP operator (DPA not pre-configured — students set it up in the backup-restore module using NooBaa for S3 storage)

### Developer Experience
- `ocp4_days_workload_rhdh` - Red Hat Developer Hub with guest auth (no complex identity setup needed for single-user workshops)

### OpenShift Lightspeed
- `ocp4_workload_ols_cleanup` - Deletes the OLSConfig created by the upstream OLS role so students create it manually in the lab module. The upstream role defaults `ocp4_workload_ai_platform: azure` which we can't override. Operator and Azure credentials secret remain intact

### Local Overrides (CatalogSource namespace fixes)
Local copies of upstream `core_workloads` roles whose hardcoded `install_operator_catalogsource_namespace` causes OLM to create a duplicate, fragile per-role CatalogSource mirror instead of reusing the shared `redhat-operators-snapshot`. Each makes the namespace configurable via a role variable instead.
- `ocp4_workload_metallb`
- `ocp4_workload_openshift_gitops`
- `ocp4_workload_openshift_virtualization`
- `ocp4_workload_web_terminal`

### Temporary Copies (from upstream core_workloads)
Unmodified copies of upstream roles, used when upstream had issues. Should be removed once no longer required.
- `ocp4_workload_pipelines_temp`
- `ocp4_workload_rhacm_temp`

## Usage

```yaml
- name: Deploy Ops Track Workshop
  hosts: localhost
  tasks:
    - ansible.builtin.include_role:
        name: openshift_days.ops_track.ocp4_workload_days_ops_track
      vars:
        ACTION: create
```

## License

GPL-2.0-or-later
