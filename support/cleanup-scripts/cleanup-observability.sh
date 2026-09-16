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

# Remove the tracing stack
(
  oc delete opentelemetrycollector otel -n tracing-system --ignore-not-found
  oc delete uiplugin distributed-tracing --ignore-not-found
  oc delete tempomonolithic sample -n tracing-system --ignore-not-found
  oc delete clusterrolebinding tempomonolithic-traces-reader tempomonolithic-traces-write --ignore-not-found
  oc delete clusterrole tempomonolithic-traces-reader tempomonolithic-traces-write --ignore-not-found
  oc delete sa otel-collector -n tracing-system --ignore-not-found
  oc delete namespace tracing-system --ignore-not-found --wait=false
) &>/dev/null &

# Remove the logging stack
(
  oc delete clusterlogforwarder collector -n openshift-logging --ignore-not-found
  oc delete uiplugin logging --ignore-not-found
  oc delete lokistack logging-loki -n openshift-logging --ignore-not-found
  oc delete obc loki-bucket -n openshift-logging --ignore-not-found
  oc delete secret lokistack-dev-s3 -n openshift-logging --ignore-not-found
  oc delete configmap loki-s3-ca -n openshift-logging --ignore-not-found
  oc delete sa collector -n openshift-logging --ignore-not-found
) &>/dev/null &

echo "Cleanup running in background — you can continue to the next module"
