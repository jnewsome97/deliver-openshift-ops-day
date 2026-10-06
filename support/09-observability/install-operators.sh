#!/bin/bash
set -euo pipefail

csv_succeeded() {
  local prefix=$1 ns=$2
  oc get csv -n "$ns" --no-headers 2>/dev/null | grep "^${prefix}" | grep -q "Succeeded"
}

snapshot_channel() {
  local name=$1
  oc get packagemanifest "$name" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null
}

ensure_snapshot_sub() {
  local pkg=$1 ns=$2 subname=${3:-$1}
  if csv_succeeded "$pkg" "$ns"; then
    echo "$pkg already installed in $ns, skipping"
    return
  fi
  local channel
  channel=$(snapshot_channel "$pkg")
  if [ -z "$channel" ]; then
    echo "ERROR: $pkg not found in redhat-operators-snapshot catalog" >&2
    return 1
  fi
  echo "Installing $pkg from snapshot channel $channel..."
  oc apply -f - <<SUBEOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${subname}
  namespace: ${ns}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${pkg}
  source: redhat-operators-snapshot
  sourceNamespace: openshift-marketplace
SUBEOF
}

ensure_live_sub() {
  local pkg=$1 ns=$2 subname=${3:-$1} channel=${4:-stable}
  if csv_succeeded "$pkg" "$ns"; then
    echo "$pkg already installed in $ns, skipping"
    return
  fi
  echo "Installing $pkg from redhat-operators channel $channel..."
  oc apply -f - <<SUBEOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${subname}
  namespace: ${ns}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${pkg}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
SUBEOF
}

oc create namespace openshift-logging 2>/dev/null || true
oc create namespace openshift-operators-redhat 2>/dev/null || true

if ! oc get operatorgroup -n openshift-logging --no-headers 2>/dev/null | grep -q .; then
  oc apply -f - <<OGEOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
    - openshift-logging
OGEOF
fi

if ! oc get operatorgroup -n openshift-operators-redhat --no-headers 2>/dev/null | grep -q .; then
  oc apply -f - <<OGEOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat
  namespace: openshift-operators-redhat
spec: {}
OGEOF
fi

ensure_snapshot_sub loki-operator      openshift-operators-redhat loki-operator
ensure_snapshot_sub cluster-logging    openshift-logging          cluster-logging
ensure_live_sub     cluster-observability-operator openshift-operators cluster-observability-operator stable
ensure_live_sub     tempo-product      openshift-operators        tempo-product      stable
ensure_live_sub     opentelemetry-product openshift-operators     opentelemetry-product stable

echo "Waiting for all 5 operators (this may take a few minutes)..."
TIMEOUT=600; ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  READY=0
  csv_succeeded loki-operator                  openshift-operators-redhat && READY=$((READY+1))
  csv_succeeded cluster-logging                openshift-logging          && READY=$((READY+1))
  csv_succeeded cluster-observability-operator openshift-operators        && READY=$((READY+1))
  csv_succeeded tempo-operator                 openshift-operators        && READY=$((READY+1))
  csv_succeeded opentelemetry-operator         openshift-operators        && READY=$((READY+1))
  echo "  ${READY}/5 operators ready"
  [ $READY -eq 5 ] && break
  sleep 15; ELAPSED=$((ELAPSED+15))
done
[ $READY -eq 5 ] && echo "All operators installed" || echo "ERROR: Timed out - check Ecosystem -> Installed Operators"
