#!/bin/bash
# Setup script for RHDH Module 12 - Developer Hub
# Creates a fully populated Developer Hub with multiple teams, live workloads,
# Kubernetes/Topology plugins, and a working software template.
#
# Prerequisites:
#   - Logged into OpenShift as admin
#   - RHDH operator installed
#   - Backstage CR 'developer-hub' exists in namespace 'backstage'
#
# Usage: bash setup-developer-hub.sh

set -euo pipefail

echo "============================================"
echo " Setting up Developer Hub for Ops Workshop"
echo "============================================"
echo ""

# -------------------------------------------------------------------
# 1. Service Account + RBAC
# -------------------------------------------------------------------
echo "[1/7] Creating service account and RBAC..."

cat <<'RBAC_EOF' | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-kubernetes-plugin
  namespace: backstage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-cluster-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-reader
subjects:
  - kind: ServiceAccount
    name: rhdh-kubernetes-plugin
    namespace: backstage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhdh-scaffolder
rules:
  - apiGroups: [""]
    resources: ["namespaces", "services", "configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-scaffolder-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rhdh-scaffolder
subjects:
  - kind: ServiceAccount
    name: rhdh-kubernetes-plugin
    namespace: backstage
RBAC_EOF

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 2. Team workloads
# -------------------------------------------------------------------
echo "[2/7] Creating team namespaces and workloads..."

# Payments team - 3 microservices
oc create namespace payments-team 2>/dev/null || true
for dep in payments-api payments-processor payments-gateway; do
  oc create deployment $dep --image=registry.access.redhat.com/ubi9/httpd-24 -n payments-team 2>/dev/null || true
done
for dep in payments-api payments-processor payments-gateway; do
  oc patch deployment $dep -n payments-team --type=json \
    -p '[{"op":"add","path":"/spec/template/metadata/labels/backstage.io~1kubernetes-id","value":"payments-platform"}]' 2>/dev/null || true
done

# Inventory team - 3 microservices
oc create namespace inventory-team 2>/dev/null || true
for dep in inventory-api inventory-worker inventory-db-sync; do
  oc create deployment $dep --image=registry.access.redhat.com/ubi9/httpd-24 -n inventory-team 2>/dev/null || true
done
for dep in inventory-api inventory-worker inventory-db-sync; do
  oc patch deployment $dep -n inventory-team --type=json \
    -p '[{"op":"add","path":"/spec/template/metadata/labels/backstage.io~1kubernetes-id","value":"inventory-system"}]' 2>/dev/null || true
done

# Inventory team - broken db migrator (crashloops for troubleshooting exercise)
oc create deployment inventory-db-migrator \
  --image=registry.access.redhat.com/ubi9/ubi-minimal \
  -n inventory-team 2>/dev/null -- /bin/sh -c "echo 'FATAL: Cannot connect to database at postgres.inventory-team:5432 - connection refused' && sleep 2 && exit 1" || true
oc patch deployment inventory-db-migrator -n inventory-team --type=json \
  -p '[{"op":"add","path":"/spec/template/metadata/labels/backstage.io~1kubernetes-id","value":"inventory-system"}]' 2>/dev/null || true

# Platform services - 1 service
oc create namespace platform-services 2>/dev/null || true
oc create deployment notification-service --image=registry.access.redhat.com/ubi9/httpd-24 -n platform-services 2>/dev/null || true
oc patch deployment notification-service -n platform-services --type=json \
  -p '[{"op":"add","path":"/spec/template/metadata/labels/backstage.io~1kubernetes-id","value":"notification-service"}]' 2>/dev/null || true

# Weather app (from debugging module - may already exist)
oc create namespace ops-track-demo 2>/dev/null || true
for dep in weather-api weather-backend weather-cache weather-frontend weather-proxy; do
  oc create deployment $dep --image=registry.access.redhat.com/ubi9/httpd-24 -n ops-track-demo 2>/dev/null || true
done
for dep in weather-api weather-backend weather-cache weather-frontend weather-proxy; do
  oc patch deployment $dep -n ops-track-demo --type=json \
    -p '[{"op":"add","path":"/spec/template/metadata/labels/backstage.io~1kubernetes-id","value":"weather-app"}]' 2>/dev/null || true
done

echo "  Waiting for pods to start..."
for ns in payments-team inventory-team platform-services ops-track-demo; do
  for dep in $(oc get deployments -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc rollout status deployment/$dep -n $ns --timeout=120s 2>/dev/null || true
  done
done

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 3. Dynamic plugins
# -------------------------------------------------------------------
echo "[3/7] Enabling dynamic plugins..."

cat <<'PLUGINS_EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dynamic-plugins-rhdh
  namespace: backstage
data:
  dynamic-plugins.yaml: |
    includes:
      - dynamic-plugins.default.yaml
    plugins:
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-community-plugin-topology
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-community-plugin-scaffolder-backend-module-kubernetes-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/roadiehq-scaffolder-backend-module-http-request-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/red-hat-developer-hub-backstage-plugin-quickstart
        disabled: true
PLUGINS_EOF

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 4. Catalog ConfigMap (with template - needs cluster-specific values)
# -------------------------------------------------------------------
echo "[4/7] Creating catalog entries and software template..."

API_URL=$(oc whoami --show-server)
SA_TOKEN=$(oc create token rhdh-kubernetes-plugin -n backstage --duration=8760h)

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: pre-built-catalog
  namespace: backstage
data:
  catalog-info.yaml: |
    apiVersion: backstage.io/v1alpha1
    kind: Group
    metadata:
      name: ops-team
      description: Operations team responsible for platform infrastructure
    spec:
      type: team
      children: []
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Group
    metadata:
      name: payments-team
      description: Payments processing team
    spec:
      type: team
      children: []
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Group
    metadata:
      name: inventory-team
      description: Inventory management team
    spec:
      type: team
      children: []
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Group
    metadata:
      name: platform-team
      description: Platform engineering team
    spec:
      type: team
      children: []
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: weather-app
      description: Weather microservices application used in the Ops Track troubleshooting module
      annotations:
        backstage.io/kubernetes-namespace: ops-track-demo
        backstage.io/kubernetes-id: weather-app
      tags:
        - openshift
        - ops-track
        - httpd
    spec:
      type: service
      lifecycle: production
      owner: ops-team
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: backup-demo-app
      description: Web application protected by OADP backup and restore
      annotations:
        backstage.io/kubernetes-namespace: backup-demo
        backstage.io/kubernetes-id: backup-demo-app
      tags:
        - openshift
        - ops-track
        - oadp
    spec:
      type: service
      lifecycle: production
      owner: ops-team
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: payments-platform
      description: Payment processing microservices - handles transactions, gateway routing, and payment processing
      annotations:
        backstage.io/kubernetes-namespace: payments-team
        backstage.io/kubernetes-id: payments-platform
      tags:
        - openshift
        - payments
        - pci
    spec:
      type: service
      lifecycle: production
      owner: payments-team
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: inventory-system
      description: Inventory tracking system - real-time stock levels, warehouse sync, and API
      annotations:
        backstage.io/kubernetes-namespace: inventory-team
        backstage.io/kubernetes-id: inventory-system
      tags:
        - openshift
        - inventory
        - supply-chain
    spec:
      type: service
      lifecycle: production
      owner: inventory-team
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: notification-service
      description: Centralized notification service - email, SMS, and in-app alerts
      annotations:
        backstage.io/kubernetes-namespace: platform-services
        backstage.io/kubernetes-id: notification-service
      tags:
        - openshift
        - platform
        - notifications
    spec:
      type: service
      lifecycle: production
      owner: platform-team
    ---
    apiVersion: backstage.io/v1alpha1
    kind: Component
    metadata:
      name: order-tracker
      description: Real-time order tracking service - not yet deployed
      annotations:
        backstage.io/kubernetes-namespace: order-tracker
        backstage.io/kubernetes-id: order-tracker
      tags:
        - openshift
        - orders
        - pending-deployment
    spec:
      type: service
      lifecycle: development
      owner: inventory-team
    ---
    apiVersion: scaffolder.backstage.io/v1beta3
    kind: Template
    metadata:
      name: deploy-service
      title: Deploy a New Service
      description: Self-service namespace provisioning for new services
      tags:
        - openshift
        - self-service
    spec:
      owner: ops-team
      type: service
      parameters:
        - title: Service Details
          required:
            - serviceName
            - teamName
            - description
          properties:
            serviceName:
              title: Service Name
              type: string
              description: Name of the new service (lowercase, no spaces)
              pattern: '^[a-z0-9-]+\$'
              ui:autofocus: true
            teamName:
              title: Team Name
              type: string
              description: Which team owns this service?
              enum:
                - payments-team
                - inventory-team
                - platform-team
                - ops-team
            description:
              title: Description
              type: string
              description: Brief description of the service
            lifecycle:
              title: Lifecycle
              type: string
              description: Service lifecycle stage
              default: production
              enum:
                - development
                - staging
                - production
      steps:
        - id: create-namespace
          name: Create OpenShift Namespace
          action: kubernetes:create-namespace
          input:
            namespace: \${{ parameters.serviceName }}
            url: ${API_URL}
            token: ${SA_TOKEN}
            skipTLSVerify: true
            labels: 'backstage.io/service=\${{ parameters.serviceName }};team=\${{ parameters.teamName }}'
        - id: deploy-api
          name: Deploy API Service
          action: http:backstage:request
          input:
            method: POST
            path: kubernetes/proxy/apis/apps/v1/namespaces/\${{ parameters.serviceName }}/deployments
            headers:
              Content-Type: application/json
            body:
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: \${{ parameters.serviceName }}-api
                namespace: \${{ parameters.serviceName }}
              spec:
                replicas: 1
                selector:
                  matchLabels:
                    app: \${{ parameters.serviceName }}-api
                template:
                  metadata:
                    labels:
                      app: \${{ parameters.serviceName }}-api
                      backstage.io/kubernetes-id: \${{ parameters.serviceName }}
                  spec:
                    containers:
                      - name: httpd
                        image: registry.access.redhat.com/ubi9/httpd-24
                        ports:
                          - containerPort: 8080
        - id: deploy-worker
          name: Deploy Worker Service
          action: http:backstage:request
          input:
            method: POST
            path: kubernetes/proxy/apis/apps/v1/namespaces/\${{ parameters.serviceName }}/deployments
            headers:
              Content-Type: application/json
            body:
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: \${{ parameters.serviceName }}-worker
                namespace: \${{ parameters.serviceName }}
              spec:
                replicas: 1
                selector:
                  matchLabels:
                    app: \${{ parameters.serviceName }}-worker
                template:
                  metadata:
                    labels:
                      app: \${{ parameters.serviceName }}-worker
                      backstage.io/kubernetes-id: \${{ parameters.serviceName }}
                  spec:
                    containers:
                      - name: httpd
                        image: registry.access.redhat.com/ubi9/httpd-24
                        ports:
                          - containerPort: 8080
        - id: log-success
          name: Log Result
          action: debug:log
          input:
            message: 'Service \${{ parameters.serviceName }} deployed with API and worker pods for team \${{ parameters.teamName }}'
      output:
        text:
          - title: Service Deployed
            content: |
              Service \${{ parameters.serviceName }} has been deployed for \${{ parameters.teamName }}.

              Created:
              - Namespace \${{ parameters.serviceName }}
              - Deployment \${{ parameters.serviceName }}-api
              - Deployment \${{ parameters.serviceName }}-worker

              The pods are already labeled for Developer Hub. Check the Kubernetes tab in the catalog.
EOF

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 5. App config
# -------------------------------------------------------------------
echo "[5/7] Configuring RHDH app-config..."

CONSOLE_URL=$(oc get route console -n openshift-console -o jsonpath='https://{.spec.host}')

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh
  namespace: backstage
data:
  app-config-rhdh.yaml: |
    auth:
      environment: development
      providers:
        guest:
          dangerouslyAllowOutsideDevelopment: true
    backend:
      reading:
        allow:
          - host: github.com
          - host: raw.githubusercontent.com
    kubernetes:
      serviceLocatorMethod:
        type: multiTenant
      clusterLocatorMethods:
        - type: config
          clusters:
            - name: openshift
              url: ${API_URL}
              authProvider: serviceAccount
              skipTLSVerify: true
              serviceAccountToken: \${K8S_PLUGIN_SA_TOKEN}
              dashboardUrl: ${CONSOLE_URL}
              dashboardApp: openshift
    catalog:
      locations:
        - type: file
          target: /opt/app-root/src/catalog-info.yaml
          rules:
            - allow: [Component, Group, Template]
EOF

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 6. SA token secret + Backstage CR patch
# -------------------------------------------------------------------
echo "[6/7] Patching Backstage CR..."

SA_TOKEN_FOR_SECRET=$(oc create token rhdh-kubernetes-plugin -n backstage --duration=8760h)
oc create secret generic rhdh-kubernetes-plugin-token -n backstage \
  --from-literal=K8S_PLUGIN_SA_TOKEN="$SA_TOKEN_FOR_SECRET" \
  --dry-run=client -o yaml | oc apply -f -

oc patch backstage developer-hub -n backstage --type=merge -p '{
  "spec": {
    "application": {
      "dynamicPluginsConfigMapName": "dynamic-plugins-rhdh",
      "extraEnvs": {
        "envs": [
          {
            "name": "NODE_TLS_REJECT_UNAUTHORIZED",
            "value": "0"
          }
        ],
        "secrets": [
          {
            "name": "rhdh-kubernetes-plugin-token"
          }
        ]
      },
      "extraFiles": {
        "mountPath": "/opt/app-root/src",
        "configMaps": [
          {
            "name": "pre-built-catalog"
          }
        ]
      }
    }
  }
}'

echo "  Waiting for RHDH rollout (this takes 2-3 minutes)..."
oc rollout status deployment/backstage-developer-hub -n backstage --timeout=600s || \
  echo "  Rollout still progressing - check: oc get pods -n backstage"

echo "  Done."
echo ""

# -------------------------------------------------------------------
# 7. Verify
# -------------------------------------------------------------------
echo "[7/7] Verifying setup..."
echo ""

echo "  Waiting for catalog to process..."
sleep 90

RHDH_URL="https://$(oc get route backstage-developer-hub -n backstage -o jsonpath='{.spec.host}')"
TOKEN=$(curl -sk "$RHDH_URL/api/auth/guest/refresh" -X POST | python3 -c "import sys,json; print(json.load(sys.stdin)['backstageIdentity']['token'])")

echo "  Pods:"
oc get pods -n backstage --no-headers | sed 's/^/    /'
echo ""

echo "  Workloads:"
for ns in ops-track-demo payments-team inventory-team platform-services; do
  count=$(oc get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
  echo "    $ns: $count running pods"
done
echo ""

echo "  Catalog Components:"
curl -sk -H "Authorization: Bearer $TOKEN" "$RHDH_URL/api/catalog/entities?filter=kind=component" | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    ns = e['metadata'].get('annotations',{}).get('backstage.io/kubernetes-namespace','?')
    lc = e['spec'].get('lifecycle','?')
    print(f\"    {e['metadata']['name']} | {e['spec']['owner']} | {lc} | ns: {ns}\")
" 2>/dev/null
echo ""

echo "  Templates:"
curl -sk -H "Authorization: Bearer $TOKEN" "$RHDH_URL/api/catalog/entities?filter=kind=template" | python3 -c "
import sys, json
entities = json.load(sys.stdin)
if not entities: print('    WARNING: No templates registered! Catalog may still be processing - wait 30s and check again.')
for e in entities:
    print(f\"    {e['metadata']['name']}: {e['metadata'].get('title','')}\")
" 2>/dev/null
echo ""

echo "  Scaffolder Actions:"
curl -sk -H "Authorization: Bearer $TOKEN" "$RHDH_URL/api/scaffolder/v2/actions" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    if 'kubernetes' in a['id'] or 'http' in a['id']:
        print(f\"    {a['id']}\")
" 2>/dev/null
echo ""

echo "============================================"
echo " Setup complete!"
echo ""
echo " RHDH URL: $RHDH_URL"
echo ""
echo " Catalog: 6 components, 4 groups, 1 template"
echo " Workloads: 12 pods across 4 namespaces"
echo "============================================"
