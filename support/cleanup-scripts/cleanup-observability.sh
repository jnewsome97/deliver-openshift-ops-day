#!/bin/bash
# Cleanup script for Module 09 - Observability & Logging
# Removes alerting rules, tracing stack, and logging stack

echo "Cleaning up observability resources..."

# Remove the custom alerting rule
oc delete prometheusrule ops-track-alerts -n openshift-monitoring --ignore-not-found

# Restore Alertmanager to defaults (in case student skipped the restore step)
cat <<'AMEOF' > /tmp/alertmanager-default.yaml
global:
  resolve_timeout: 5m
inhibit_rules:
- equal:
  - namespace
  - alertname
  source_matchers:
  - "severity = critical"
  target_matchers:
  - "severity =~ warning|info"
- equal:
  - namespace
  - alertname
  source_matchers:
  - "severity = warning"
  target_matchers:
  - "severity = info"
receivers:
- name: Default
- name: Watchdog
- name: Critical
route:
  group_by:
  - namespace
  group_interval: "5m"
  group_wait: "30s"
  receiver: Default
  repeat_interval: "12h"
  routes:
  - matchers:
    - "alertname = Watchdog"
    receiver: Watchdog
  - matchers:
    - "severity = critical"
    receiver: Critical
AMEOF
oc create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager-default.yaml \
  -n openshift-monitoring \
  --dry-run=client -o yaml | oc replace -f - 2>/dev/null
rm -f /tmp/alertmanager-default.yaml

# Remove alert-demo namespace (mailpit + crashloop test resources)
oc delete namespace alert-demo --ignore-not-found --wait=false &>/dev/null
# Remove the dedicated low-volume logging demo namespace
oc delete namespace observability-demo --ignore-not-found --wait=false &>/dev/null

# Removing the distributed-tracing and logging UIPlugins unregisters them from the
# console operator, which restarts the console Deployment - same class of problem
# as enabling them in enable-logging-ui.sh (module 09). Delete them synchronously,
# up front, and wait for the console to actually settle before telling the user
# it's safe to continue, instead of backgrounding everything as before and
# declaring success immediately with no wait.
CONSOLE_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")

echo "Removing the distributed-tracing and logging console UIPlugins..."
oc delete uiplugin distributed-tracing --ignore-not-found
oc delete uiplugin logging --ignore-not-found

echo "Waiting for the console operator to pick up the plugin removal..."
ELAPSED=0
until [ "$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$CONSOLE_GEN")" != "$CONSOLE_GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 30 ] && echo "  console generation unchanged after 30s - plugin removal may not have triggered a restart, continuing" && break
done

REQUIRED_STABLE_SECS=30
MAX_WAIT_SECS=300
STABLE_FOR=0
TOTAL_ELAPSED=0
LAST_GEN="$CONSOLE_GEN"

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

# "oc get deployment console" only reports the Deployment's own state - it says
# nothing about whether the public console route (what a real login/reload
# actually hits) has caught up. Confirm it's actually reachable too before
# declaring success - see configure-oauth-ldap.sh for the same check and why
# it's needed.
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
echo "Confirming the console route is actually reachable before declaring it safe to continue..."
[ -n "$CONSOLE_HOST" ] && wait_for_route_reachable "https://${CONSOLE_HOST}/" "console route"

echo "Console UIPlugins removed and console has been stable - it is now safe to continue to the next module"

# Remove the remaining tracing stack resources - these don't touch the console
# or oauth, so they're safe to tear down in the background.
(
  oc delete opentelemetrycollector otel -n tracing-system --ignore-not-found
  oc delete tempomonolithic sample -n tracing-system --ignore-not-found
  oc delete clusterrolebinding tempomonolithic-traces-reader tempomonolithic-traces-write --ignore-not-found
  oc delete clusterrole tempomonolithic-traces-reader tempomonolithic-traces-write --ignore-not-found
  oc delete sa otel-collector -n tracing-system --ignore-not-found
  oc delete namespace tracing-system --ignore-not-found --wait=false
) &>/dev/null &

# Remove the remaining logging stack resources - these don't touch the console
# or oauth, so they're safe to tear down in the background.
(
  oc delete clusterlogforwarder collector -n openshift-logging --ignore-not-found
  oc delete lokistack logging-loki -n openshift-logging --ignore-not-found
  oc delete obc loki-bucket -n openshift-logging --ignore-not-found
  oc delete pvc storage-logging-loki-compactor-0 storage-logging-loki-index-gateway-0 \
    storage-logging-loki-ingester-0 wal-logging-loki-ingester-0 \
    -n openshift-logging --ignore-not-found --wait=true
  oc delete secret lokistack-dev-s3 -n openshift-logging --ignore-not-found
  oc delete configmap loki-s3-ca -n openshift-logging --ignore-not-found
  oc delete sa collector -n openshift-logging --ignore-not-found
) &>/dev/null &

echo "Remaining namespace and storage teardown continues in the background."
