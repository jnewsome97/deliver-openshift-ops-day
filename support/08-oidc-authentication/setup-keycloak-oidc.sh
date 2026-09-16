#!/bin/bash
# Configure Keycloak with users, groups, and OIDC client for OpenShift

set -euo pipefail

KEYCLOAK_URL="https://$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')"
KC_ADMIN_USER=$(oc get secret keycloak-initial-admin -n rhbk -o jsonpath='{.data.username}' | base64 -d)
KC_ADMIN_PASS=$(oc get secret keycloak-initial-admin -n rhbk -o jsonpath='{.data.password}' | base64 -d)
OAUTH_CALLBACK="https://oauth-openshift.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')/oauth2callback/rhbk"

# Get admin token
TOKEN=$(curl -sk "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=admin-cli" \
  -d "username=${KC_ADMIN_USER}" -d "password=${KC_ADMIN_PASS}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "=== Creating remaining users ==="
for user in developer1 viewer1; do
  FIRST=$(echo $user | sed 's/1$//' | sed 's/.*/\u&/')
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/OpenShift/users" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"email\":\"${user}@example.com\",\"firstName\":\"${FIRST}\",\"lastName\":\"User\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"OpenShift123!\",\"temporary\":false}]}"
  echo "  Created $user"
done

echo "=== Creating remaining groups ==="
for group in ocp-developers ocp-viewers; do
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/OpenShift/groups" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"${group}\"}"
  echo "  Created $group"
done

echo "=== Assigning users to groups ==="
DEV1_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/users?username=developer1" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
VIEWER1_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/users?username=viewer1" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
DEVS_GID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/groups?search=ocp-developers" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
VIEWERS_GID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/groups?search=ocp-viewers" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/OpenShift/users/${DEV1_ID}/groups/${DEVS_GID}" \
  -H "Authorization: Bearer $TOKEN"
echo "  developer1 -> ocp-developers"
curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/OpenShift/users/${VIEWER1_ID}/groups/${VIEWERS_GID}" \
  -H "Authorization: Bearer $TOKEN"
echo "  viewer1 -> ocp-viewers"

echo "=== Creating OIDC client ==="
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/OpenShift/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"openshift\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":false,\"clientAuthenticatorType\":\"client-secret\",\"redirectUris\":[\"${OAUTH_CALLBACK}\"],\"directAccessGrantsEnabled\":true}"
echo "  Client 'openshift' created with redirect URI"

CLIENT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/clients?clientId=openshift" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

echo "=== Adding groups claim mapper ==="
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/OpenShift/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}'
echo "  Groups mapper added - ID tokens will include group membership"

echo "=== Fetching client secret ==="
CLIENT_SECRET=$(curl -sk "${KEYCLOAK_URL}/admin/realms/OpenShift/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
echo "  Client secret retrieved automatically"

echo "=== Creating OpenShift client secret ==="
oc delete secret rhbk-client-secret -n openshift-config 2>/dev/null || true
oc create secret generic rhbk-client-secret \
  --from-literal=clientSecret="${CLIENT_SECRET}" \
  -n openshift-config
echo "  Secret rhbk-client-secret created in openshift-config"

echo ""
echo "Done - Keycloak is fully configured"
