#!/bin/bash
# Cleanup script for Module 07 - LDAP Authentication
# Restores OAuth to htpasswd only, removes LDAP resources
# NOTE: Caller must be logged in as admin before running this script

echo "Cleaning up LDAP resources..."

# Verify we're logged in as admin
if ! oc whoami | grep -q admin; then
  echo "ERROR: Not logged in as admin — run 'oc login -u admin' first"
  exit 1
fi

# Restore OAuth to htpasswd only
cat <<'EOF' | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswd
EOF

# Remove LDAP secrets and config
oc delete secret ldap-secret -n openshift-config --ignore-not-found
oc delete configmap ca-config-map -n openshift-config --ignore-not-found

# Remove LDAP users, identities, and groups
oc delete user normaluser1 fancyuser1 fancyuser2 teamuser1 teamuser2 --ignore-not-found
oc delete identity ldap:normaluser1 ldap:fancyuser1 ldap:fancyuser2 ldap:teamuser1 ldap:teamuser2 --ignore-not-found
oc delete group ose-fancy-dev ose-normal-dev ose-teamed-app ose-user --ignore-not-found

# Remove RBAC bindings
oc adm policy remove-cluster-role-from-user cluster-admin fancyuser1 2>/dev/null || true
oc adm policy remove-cluster-role-from-group cluster-reader ose-fancy-dev 2>/dev/null || true

# Remove test projects; wait for OAuth rollout before removing the in-cluster LDAP server
# so OAuth pods do not attempt LDAP connections against a namespace that no longer exists.
(
  oc delete project app-dev app-test app-prod --ignore-not-found
  oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout=120s
  oc delete project glauth --ignore-not-found
) &>/dev/null &

echo "Cleanup running in background — OAuth restoring to htpasswd only. You can continue to the next module."
