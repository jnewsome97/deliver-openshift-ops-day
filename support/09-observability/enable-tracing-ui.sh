#!/bin/bash
set -uo pipefail
# Enables the Observe -> Traces view in the OpenShift console (Module 09).
#
# Creating the DistributedTracing UIPlugin CR restarts the console Deployment -
# same class of problem as the OAuth identity-provider changes in modules 07/08
# and the Logging UIPlugin in enable-logging-ui.sh. Log out before running
# this script and do not log back in until it prints that it is safe.
echo "NOTE: log out of the OCP Console tab before running this script, and do not log back in until it finishes."

_set_acm_mce_console_enabled() {
  local target="$1" verb
  [ "$target" = "true" ] && verb="Re-enabling" || verb="Disabling"
  echo "${verb} ACM/MCE console plugins..."
  if oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null 2>&1; then
    local patch
    patch=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o json | python3 -c "
import json, sys
enabled = '$target' == 'true'
mch = json.load(sys.stdin)
for c in mch['spec']['overrides']['components']:
    if c['name'] == 'console':
        c['enabled'] = enabled
print(json.dumps({'spec': {'overrides': {'components': mch['spec']['overrides']['components']}}}))
")
    oc patch multiclusterhub multiclusterhub -n open-cluster-management --type=merge -p "$patch"
  fi
  if oc get multiclusterengine multiclusterengine &>/dev/null 2>&1; then
    local patch
    patch=$(oc get multiclusterengine multiclusterengine -o json | python3 -c "
import json, sys
enabled = '$target' == 'true'
mce = json.load(sys.stdin)
for c in mce['spec']['overrides']['components']:
    if c['name'] == 'console-mce':
        c['enabled'] = enabled
print(json.dumps({'spec': {'overrides': {'components': mce['spec']['overrides']['components']}}}))
")
    oc patch multiclusterengine multiclusterengine --type=merge -p "$patch"
  fi
}

GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")

_set_acm_mce_console_enabled false
echo "Waiting for console to settle after plugin-removal before applying the DistributedTracing UIPlugin..."
STABLE_FOR=0; TOTAL_ELAPSED=0; LAST_GEN="$GEN"
while :; do
  CUR_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment console -n openshift-console -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment console -n openshift-console -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment console -n openshift-console -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  if [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "${REPLICAS:-0}" ] && [ "${UPDATED:-0}" = "${REPLICAS:-0}" ] \
     && [ "${REPLICAS:-0}" -gt 0 ] && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ] && \
      echo "  console restarted (generation $LAST_GEN -> $CUR_GEN) - resetting stability timer"
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"
  [ "$STABLE_FOR" -ge 30 ] && break
  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  [ "$TOTAL_ELAPSED" -ge 300 ] && break
done
GEN="$LAST_GEN"

echo "Applying the DistributedTracing UIPlugin..."
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing
spec:
  type: DistributedTracing
EOF

echo "Waiting for the console operator to pick up the plugin change..."
ELAPSED=0
until [ "$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$GEN")" != "$GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 60 ] && echo "Warning: console operator slow to pick up the plugin change - continuing to wait below" && break
done

REQUIRED_STABLE_SECS=30
MAX_WAIT_SECS=300
STABLE_FOR=0
TOTAL_ELAPSED=0
LAST_GEN="$GEN"

while :; do
  CUR_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment console -n openshift-console -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment console -n openshift-console -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment console -n openshift-console -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  if [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "${REPLICAS:-0}" ] && [ "${UPDATED:-0}" = "${REPLICAS:-0}" ] \
     && [ "${REPLICAS:-0}" -gt 0 ] && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    if [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ]; then
      echo "  console restarted again (generation $LAST_GEN -> $CUR_GEN) - this is expected, resetting the stability timer"
    fi
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"
  [ "$STABLE_FOR" -ge "$REQUIRED_STABLE_SECS" ] && break
  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  if [ "$TOTAL_ELAPSED" -ge "$MAX_WAIT_SECS" ]; then
    echo "ERROR: Timed out after ${MAX_WAIT_SECS}s waiting for console to stabilize - check 'oc get co console' and 'oc get pods -n openshift-console'"
    break
  fi
done

_set_acm_mce_console_enabled true
echo "Waiting for the console to stabilize after restoring ACM/MCE plugins..."
STABLE_FOR=0; TOTAL_ELAPSED=0; LAST_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
while :; do
  CUR_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment console -n openshift-console -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment console -n openshift-console -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment console -n openshift-console -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  if [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "${REPLICAS:-0}" ] && [ "${UPDATED:-0}" = "${REPLICAS:-0}" ] \
     && [ "${REPLICAS:-0}" -gt 0 ] && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ] && \
      echo "  console restarted (generation $LAST_GEN -> $CUR_GEN) - resetting stability timer"
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"
  [ "$STABLE_FOR" -ge 30 ] && break
  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  [ "$TOTAL_ELAPSED" -ge 300 ] && echo "WARNING: Timed out waiting for console to stabilize after ACM/MCE restore" && break
done

wait_for_route_reachable() {
  local url="$1" label="$2"
  local required_ok=10 max_wait=120 ok_streak=0 elapsed=0
  while :; do
    local code
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ] || [ "$code" = "403" ]; then
      ok_streak=$((ok_streak+1))
    else
      [ "$ok_streak" -gt 0 ] && echo "  $label returned $code - resetting reachability streak"
      ok_streak=0
    fi
    [ "$ok_streak" -ge "$required_ok" ] && return 0
    sleep 1; elapsed=$((elapsed+1))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "WARNING: $label did not stay reachable for ${required_ok}s straight within ${max_wait}s - continuing anyway, but logging back in right now may still hit a transient failure"
      return 1
    fi
  done
}

CONSOLE_HOST=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)
echo "Confirming the console route is actually reachable before declaring it safe to log back in..."
[ -n "$CONSOLE_HOST" ] && wait_for_route_reachable "https://${CONSOLE_HOST}/" "console route"

echo "DistributedTracing UIPlugin applied and console has been stable - it is now safe to log back into the console"
