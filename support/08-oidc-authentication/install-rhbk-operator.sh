#!/bin/bash
set -euo pipefail

oc create namespace rhbk 2>/dev/null || true

if ! oc get operatorgroup -n rhbk --no-headers 2>/dev/null | grep -q .; then
  oc apply -f - <<OGEOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk
  namespace: rhbk
spec:
  targetNamespaces:
  - rhbk
OGEOF
fi

if oc get csv -n rhbk --no-headers 2>/dev/null | grep "^rhbk-operator" | grep -q Succeeded; then
  echo "rhbk-operator already installed, skipping"
else
  channel=$(oc get packagemanifest rhbk-operator -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
  if [ -z "$channel" ]; then
    echo "ERROR: rhbk-operator not found in redhat-operators-snapshot catalog" >&2
    exit 1
  fi
  echo "Installing rhbk-operator from snapshot channel $channel..."
  oc apply -f - <<SUBEOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: rhbk
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators-snapshot
  sourceNamespace: openshift-marketplace
SUBEOF
fi

echo "Waiting for RHBK operator..."
until oc get csv -n rhbk 2>/dev/null | grep rhbk-operator | grep -q Succeeded; do sleep 10; done
echo "Waiting for Keycloak CRD..."
until oc get crd keycloaks.k8s.keycloak.org 2>/dev/null | grep -q keycloaks; do sleep 5; done
echo "RHBK operator ready"
