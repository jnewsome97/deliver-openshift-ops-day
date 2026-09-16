#!/bin/bash
# Restore Alertmanager to default configuration and clean up alert-demo namespace
cat <<'EOF' > /tmp/alertmanager-default.yaml
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
EOF
oc create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager-default.yaml \
  -n openshift-monitoring \
  --dry-run=client -o yaml | oc replace -f -
rm /tmp/alertmanager-default.yaml
oc delete namespace alert-demo --ignore-not-found --wait=false &>/dev/null &
echo "Alertmanager restored to defaults"
