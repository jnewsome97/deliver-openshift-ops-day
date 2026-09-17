#!/bin/bash
set -euo pipefail

SUPPORT_BASE="${SUPPORT_BASE_URL:-https://raw.githubusercontent.com/rhpds/deliver-openshift-ops-day/main/support}"

oc create namespace debug-lab 2>/dev/null || true

if curl -fsSL --retry 3 --retry-delay 2 -o /tmp/broken-apps-v2.yaml "${SUPPORT_BASE}/broken-apps-v2.yaml" 2>/dev/null; then
  oc apply -f /tmp/broken-apps-v2.yaml
elif curl -fsSL --retry 3 --retry-delay 2 -o /tmp/broken-apps-v2.yaml "https://raw.githubusercontent.com/rhpds/deliver-openshift-ops-day/main/support/broken-apps-v2.yaml"; then
  oc apply -f /tmp/broken-apps-v2.yaml
else
  echo "ERROR: Could not download broken-apps-v2.yaml from the Showroom instance or GitHub. Check your network connection and re-run this command."
  exit 1
fi

echo ""
echo "Waiting for pods to reach their error states..."
ELAPSED=0
until [ $(oc get pods -n debug-lab --no-headers 2>/dev/null | grep -v ContainerCreating | wc -l) -ge 5 ]; do
  sleep 5; ELAPSED=$((ELAPSED+5))
  [ $ELAPSED -ge 120 ] && echo "Timed out waiting for pods" && break
done

echo ""
oc get pods -n debug-lab
