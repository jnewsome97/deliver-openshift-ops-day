#!/bin/bash
set -euo pipefail

cat <<EOF | oc apply -f -
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: tracing-system
spec:
  mode: deployment
  serviceAccount: otel-collector
  config:
    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        send_batch_size: 512
        timeout: 5s
    exporters:
      otlp/tempo:
        endpoint: tempo-sample-gateway.tracing-system.svc:4317
        tls:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
        headers:
          X-Scope-OrgID: dev
        auth:
          authenticator: bearertokenauth
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/tempo]
EOF
