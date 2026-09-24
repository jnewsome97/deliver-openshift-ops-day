#!/bin/bash
# Fix VMSnapshot/VMClone on clusters with External ODF storage (ODF 4.22 / OCP 4.22)
#
# Root cause: the csi-snapshotter sidecar in the RBD ctrlplugin is compiled against
# the v1beta2 VolumeGroupSnapshot API, but OCP 4.22 only serves v1. Its informer
# WaitForCacheSync blocks forever, workers never start, and no snapshot is ever
# sent to the CSI driver.
#
# Fix: set CSISnapshotController to Unmanaged so OCP stops reconciling the
# VolumeGroupSnapshot CRDs, then add v1beta2 as a served (non-stored) version
# so the informer can sync against an empty collection and workers start normally.
#
# This script is safe to run multiple times (idempotent).

set -euo pipefail

echo "=== Fixing VMSnapshot/VMClone for External ODF (ODF 4.22 / OCP 4.22) ==="

# 1. Stop OCP's csi-snapshot-controller-operator from reconciling VolumeGroupSnapshot CRDs.
#    managementState: Unmanaged means "leave existing resources alone, stop reconciling".
#    The snapshot-controller pods themselves keep running; VolumeSnapshot still works.
echo "[1/4] Setting CSISnapshotController to Unmanaged..."
oc patch csisnapshotcontroller cluster --type=merge \
  -p '{"spec":{"managementState":"Unmanaged"}}' 2>&1

# Give the operator a moment to stop its reconcile loop
sleep 5

# 2. Add v1beta2 as a served, non-stored version to each VolumeGroupSnapshot CRD.
#    The csi-snapshotter informer watches groupsnapshot.storage.k8s.io/v1beta2.
#    With v1beta2 served (even with no objects), WaitForCacheSync completes.
echo "[2/4] Adding v1beta2 to VolumeGroupSnapshot CRDs..."
for crd in volumegroupsnapshotclasses volumegroupsnapshotcontents volumegroupsnapshots; do
  CRD_FULL="${crd}.groupsnapshot.storage.k8s.io"

  # Check if v1beta2 already present
  if oc get crd "${CRD_FULL}" -o jsonpath='{range .spec.versions[*]}{.name} {end}' 2>/dev/null | grep -q "v1beta2"; then
    echo "  ${crd}: v1beta2 already present, skipping"
    continue
  fi

  CURRENT=$(oc get crd "${CRD_FULL}" -o json)
  NEW=$(echo "${CURRENT}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
versions = [v for v in d['spec']['versions'] if v['name'] != 'v1beta2']
versions.append({
  'name': 'v1beta2',
  'served': True,
  'storage': False,
  'schema': {'openAPIV3Schema': {'type': 'object', 'x-kubernetes-preserve-unknown-fields': True}}
})
d['spec']['versions'] = versions
print(json.dumps(d))
")
  echo "${NEW}" | oc replace -f - 2>&1
  echo "  ${crd}: v1beta2 added"
done

# 3. Verify all three CRDs now serve v1beta2
echo "[3/4] Verifying CRD versions..."
ALL_OK=true
for crd in volumegroupsnapshotclasses volumegroupsnapshotcontents volumegroupsnapshots; do
  VERSIONS=$(oc get crd "${crd}.groupsnapshot.storage.k8s.io" \
    -o jsonpath='{range .spec.versions[*]}{.name} {end}' 2>/dev/null)
  if echo "${VERSIONS}" | grep -q "v1beta2"; then
    echo "  ${crd}: OK (${VERSIONS})"
  else
    echo "  ${crd}: MISSING v1beta2 (${VERSIONS})"
    ALL_OK=false
  fi
done

if [ "${ALL_OK}" != "true" ]; then
  echo "ERROR: Not all CRDs were patched. Aborting."
  exit 1
fi

# 4. Rolling restart so new ctrlplugin pods start with v1beta2 available.
#    The new leader will call WaitForCacheSync, find v1beta2, and start workers.
echo "[4/4] Restarting RBD ctrlplugin deployment..."
oc rollout restart deployment/openshift-storage.rbd.csi.ceph.com-ctrlplugin \
  -n openshift-storage 2>&1
oc rollout status deployment/openshift-storage.rbd.csi.ceph.com-ctrlplugin \
  -n openshift-storage --timeout=120s 2>&1

# Wait for leader election + cache sync (up to 3 minutes)
echo "Waiting for csi-snapshotter caches to populate..."
DEADLINE=$((SECONDS + 180))
while [ $SECONDS -lt $DEADLINE ]; do
  # Find the elected leader pod
  LEADER_ID=$(oc get lease external-snapshotter-leader-openshift-storage-rbd-csi-ceph-com \
    -n openshift-storage -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  if [ -n "${LEADER_ID}" ]; then
    LEADER_POD=$(echo "${LEADER_ID}" | \
      sed 's/openshift-storage-rbd-csi-ceph-com-ctrlplugin-/openshift-storage.rbd.csi.ceph.com-ctrlplugin-/')
    SYNCED=$(oc logs -n openshift-storage "${LEADER_POD}" -c csi-snapshotter --tail=200 2>/dev/null \
      | grep "Caches populated" | wc -l)
    if [ "${SYNCED}" -ge 4 ]; then
      echo "All 4 caches populated - csi-snapshotter workers are running."
      break
    fi
  fi
  sleep 5
done

if [ $SECONDS -ge $DEADLINE ]; then
  echo "WARNING: Timed out waiting for cache sync. Check csi-snapshotter logs:"
  echo "  oc logs -n openshift-storage ${LEADER_POD:-<leader-pod>} -c csi-snapshotter --tail=50"
else
  echo ""
  echo "=== Fix applied successfully ==="
  echo "VMSnapshots and VMClones should now work on this cluster."
  echo ""
  echo "NOTE: CSISnapshotController is set to 'Unmanaged'. This is intentional."
  echo "      Revert with: oc patch csisnapshotcontroller cluster --type=merge"
  echo "                       -p '{\"spec\":{\"managementState\":\"Managed\"}}'"
fi
