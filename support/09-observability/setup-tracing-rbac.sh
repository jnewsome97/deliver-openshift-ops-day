#!/bin/bash
set -euo pipefail

cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: tracing-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempomonolithic-traces-reader
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["dev"]
    resourceNames: ["traces"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tempomonolithic-traces-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tempomonolithic-traces-reader
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:authenticated
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempomonolithic-traces-write
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["dev"]
    resourceNames: ["traces"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tempomonolithic-traces-write
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tempomonolithic-traces-write
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: tracing-system
EOF
