#!/bin/bash
set -euo pipefail

# Deploy Red Hat Build of Keycloak (RHBK) in dev mode directly as a Deployment.
# The rhbk-operator is not yet available in the OCP 5.0 operator catalog, so
# we deploy the keycloak-rhel9 image directly. start-dev uses an in-memory H2
# database — ephemeral but sufficient for the OIDC lab exercise.

ADMIN_PASSWORD="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"

oc create namespace rhbk 2>/dev/null || true

# Admin credentials — matches the secret name the lab scripts expect
oc create secret generic keycloak-initial-admin \
  --from-literal=username=admin \
  --from-literal=password="${ADMIN_PASSWORD}" \
  -n rhbk 2>/dev/null || \
oc patch secret keycloak-initial-admin -n rhbk \
  -p "{\"stringData\":{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}}" \
  --type=merge

oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: keycloak-service
  namespace: rhbk
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: rhbk
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: registry.redhat.io/rhbk/keycloak-rhel9:26.6
        args: ["start-dev", "--health-enabled=true", "--proxy-headers=xforwarded"]
        env:
        - name: KEYCLOAK_ADMIN
          value: admin
        - name: KEYCLOAK_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-initial-admin
              key: password
        ports:
        - containerPort: 8080
          name: http
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 12
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: "1"
EOF

# Create route if not already present
oc create route edge keycloak \
  --service=keycloak-service \
  --port=8080 \
  --insecure-policy=Redirect \
  -n rhbk 2>/dev/null || true

echo "Waiting for Keycloak pod..."
oc rollout status deployment/keycloak -n rhbk --timeout=300s

echo ""
echo "Keycloak URL: https://$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')"
echo "Username: admin"
echo "Password: $(oc get secret keycloak-initial-admin -n rhbk -o jsonpath='{.data.password}' | base64 -d)"
