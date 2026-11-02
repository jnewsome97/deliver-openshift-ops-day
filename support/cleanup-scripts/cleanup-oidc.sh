#!/bin/bash
set -uo pipefail
# Cleanup script for Module 08 - OIDC Authentication
# Restores OAuth to htpasswd only and removes the OIDC users/groups/RBAC.
# Deliberately leaves the rhbk namespace (Keycloak) running rather than
# tearing it down - see the note above the namespace-deletion lines this
# used to have, below.

echo "Cleaning up OIDC resources..."

GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")

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

echo "Waiting for OAuth operator to pick up the config change..."
ELAPSED=0
until [ "$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$GEN")" != "$GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 60 ] && echo "Warning: OAuth operator slow to pick up config change - continuing to wait below" && break
done

# Delete OIDC users/groups now. The client secret is left in place until the
# OAuth rollout has stabilized below - deleting it here races with the
# authentication-operator's synced copy (v4-0-config-user-idp-*-client-secret
# in openshift-authentication), which the still-rolling-out old oauth-openshift
# pod needs to mount. Pulling it out from under that pod gets it killed with a
# FailedMount error and causes a brief login outage until the new pod is up.
oc delete user developer1 admin1 viewer1 --ignore-not-found
# Only the rhbk-provider identities - not --all, which would also delete
# htpasswd:admin along with them and break admin's OAuth login until the
# Identity is recreated. Identity names are "rhbk:<subject-claim-value>"
# (a UUID from the ID token, not the username), so they have to be matched
# by prefix rather than listed by name.
oc get identity -o name | grep '^identity.user.openshift.io/rhbk:' | xargs -r oc delete --ignore-not-found
oc delete group ocp-admins ocp-developers ocp-viewers --ignore-not-found

# Remove Lightspeed RBAC granted via group sync during this module
oc adm policy remove-cluster-role-from-group lightspeed-operator-query-access ocp-developers 2>/dev/null || true
oc adm policy remove-cluster-role-from-user lightspeed-operator-query-access developer1 2>/dev/null || true

# The authentication operator applies the OAuth change above in several
# stages (trust bundle sync, cert rotation, etc.), and oauth-openshift can
# roll out more than once in a row as a result - observed live to take 6
# sequential rollouts over ~14 minutes. "oc rollout status" already knows
# how to wait for one rollout to finish; the only thing we need on top is to
# notice if another one starts right after, and wait again.
echo "Waiting for OAuth to fully stabilize - do NOT reload or log in to the OCP Console tab until this finishes."
MAX_WAIT_SECS=1200
SETTLE_SECS=30
SECONDS=0

while :; do
  REMAINING=$((MAX_WAIT_SECS - SECONDS))
  if [ "$REMAINING" -le 0 ] || ! oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout="${REMAINING}s"; then
    echo "ERROR: oauth-openshift did not finish rolling out within ${MAX_WAIT_SECS}s total."
    echo "Do NOT reload or log in to the OCP Console tab yet. Check 'oc get co authentication' and 'oc get pods -n openshift-authentication', then re-run this script once it settles."
    exit 1
  fi
  GEN_AFTER=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
  sleep "$SETTLE_SECS"
  GEN_NOW=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
  [ "$GEN_AFTER" = "$GEN_NOW" ] && break
  echo "  oauth-openshift restarted again (generation $GEN_AFTER -> $GEN_NOW) - this is expected, waiting for it to finish too"
done

# Deliberately NOT deleting the rhbk-client-secret, the rhbk namespace
# (Keycloak), or the app-development/app-production projects here. On a
# dedicated, single-attendee RHDP cluster, idle Keycloak's footprint
# (~22m CPU / ~894Mi memory, well within node capacity) is not meaningful
# resource pressure, and the multi-minute namespace/project teardown this
# used to do added real risk for no benefit: it raced the still-rolling-out
# old oauth-openshift pods against an already-deleted OIDC backend, and
# left the Console tab untouchable for the whole wait. Reverting the OAuth
# CR above is enough to fully hide OIDC from the login page; Keycloak is
# just left running unused.

# If the ACM/MCE "Fleet management" perspective was ever selected (e.g.
# while exploring the cluster earlier in the workshop), the Console
# persists that choice per-user in a ConfigMap and restores it on next
# login. Fleet management runs a 5s ACM operator-health poll plus an
# all-namespaces Events walk that has been observed to pin the embedded
# Console tab's renderer in a GC-thrashing freeze it never recovers from.
# Reset the perspective to Administrator so the next login (module 9)
# always lands on the lightweight single-cluster view instead.
echo "Resetting Console perspective to Administrator to avoid the Fleet-management freeze..."
if oc get namespace openshift-console-user-settings >/dev/null 2>&1; then
  for cm in $(oc get configmap -n openshift-console-user-settings -o name 2>/dev/null | grep '^configmap/user-settings-'); do
    oc patch -n openshift-console-user-settings "$cm" --type=merge -p '{"data":{"console.lastPerspective":"admin"}}' >/dev/null 2>&1 || true
  done
fi

# Restore the acm perspective that configure-oauth-oidc.sh temporarily
# disabled for developer1's first login - module 14 (ACM) needs it back.
if [ -f /tmp/.oidc-orig-perspectives.json ]; then
  echo "Re-enabling the ACM Fleet-management console perspective..."
  PATCH=$(python3 -c '
import json
with open("/tmp/.oidc-orig-perspectives.json") as f:
    perspectives = json.load(f)
print(json.dumps({"spec": {"customization": {"perspectives": perspectives}}}))
')
  oc patch consoles.operator.openshift.io cluster --type=merge -p "$PATCH"
  rm -f /tmp/.oidc-orig-perspectives.json

  echo "Waiting for the Console to pick up the perspective change and stabilize..."
  if ! oc rollout status deployment/console -n openshift-console --timeout=300s; then
    echo "ERROR: console did not finish rolling out within 300s."
    echo "Check 'oc get co console' and 'oc get pods -n openshift-console', then re-run this script once it settles."
    exit 1
  fi
fi

echo "Cleanup complete - it is now safe to continue to the next module"
