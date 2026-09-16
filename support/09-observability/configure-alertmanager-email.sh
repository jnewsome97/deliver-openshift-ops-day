#!/bin/bash
# Configure Alertmanager to send emails through Mailpit
# Routes warning alerts to ops-team@example.com, critical to oncall@example.com
cat <<'EOF' > /tmp/alertmanager-config.yaml
global:
  smtp_smarthost: "mailpit.alert-demo.svc:1025"
  smtp_from: "alertmanager@openshift.local"
  smtp_require_tls: false
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
  email_configs:
  - to: "ops-team@example.com"
    send_resolved: true
- name: Watchdog
- name: Critical
  email_configs:
  - to: "oncall@example.com"
    send_resolved: true
route:
  group_by:
  - namespace
  group_interval: "1m"
  group_wait: "10s"
  receiver: Default
  repeat_interval: "1m"
  routes:
  - matchers:
    - "alertname = Watchdog"
    receiver: Watchdog
  - matchers:
    - "severity = critical"
    receiver: Critical
EOF
oc create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager-config.yaml \
  -n openshift-monitoring \
  --dry-run=client -o yaml | oc replace -f -
rm /tmp/alertmanager-config.yaml
echo "Alertmanager configured - emails will arrive within 60 seconds"
echo ""
echo "Mailpit inbox: https://$(oc get route mailpit -n alert-demo -o jsonpath='{.spec.host}')"
