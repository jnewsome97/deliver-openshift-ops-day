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
# roll out more than once in a row as a result. Declaring success after the
# first rollout finishes is not safe: logging out / reloading the Console
# while a later restart is still in flight causes repeated auth failures
# against the Console's open API watches, which can freeze the Console
# tab's browser tab. Instead, wait until the cluster has been fully quiet
# for a sustained period, resetting the quiet timer every time
# oauth-openshift restarts again.
echo "Waiting for OAuth to fully stabilize - do NOT log out of or reload the OCP Console tab until this finishes."
REQUIRED_STABLE_SECS=30
MAX_WAIT_SECS=600
STABLE_FOR=0
TOTAL_ELAPSED=0
LAST_GEN="$GEN"

while :; do
  PROGRESSING=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "")
  AVAILABLE=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  DEGRADED=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  CUR_GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

  if [ "$PROGRESSING" = "False" ] && [ "$AVAILABLE" = "True" ] && [ "$DEGRADED" = "False" ] \
     && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "3" ] && [ "${UPDATED:-0}" = "3" ] && [ "${REPLICAS:-0}" = "3" ] \
     && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    if [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ]; then
      echo "  oauth-openshift restarted again (generation $LAST_GEN -> $CUR_GEN) - this is expected, resetting the stability timer"
    fi
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"

  [ "$STABLE_FOR" -ge "$REQUIRED_STABLE_SECS" ] && break

  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  if [ "$TOTAL_ELAPSED" -ge "$MAX_WAIT_SECS" ]; then
    echo "WARNING: Timed out after ${MAX_WAIT_SECS}s waiting for OAuth to stabilize - continuing to delete rhbk anyway, but check 'oc get co authentication' and 'oc get pods -n openshift-authentication'"
    break
  fi
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

echo "Cleanup complete - it is now safe to continue to the next module"
