#!/bin/bash
set -uo pipefail
# Cleanup script for Module 07 - LDAP Authentication
# Restores OAuth to htpasswd only, removes LDAP resources
# NOTE: Caller must be logged in as admin before running this script

echo "Cleaning up LDAP resources..."

# Verify we're logged in as admin
if ! oc whoami | grep -q admin; then
  echo "ERROR: Not logged in as admin — run 'oc login -u admin' first"
  exit 1
fi

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

# Remove LDAP users, identities, and groups now. The ldap-secret and
# ca-config-map are left in place until the OAuth rollout has stabilized
# below - deleting them here races with the authentication-operator's synced
# copies in openshift-authentication, which the still-rolling-out old
# LDAP-configured oauth-openshift pod needs to mount. Pulling them out from
# under that pod gets it killed with a FailedMount error and causes a brief
# login outage until the new pod is up.
oc delete user normaluser1 fancyuser1 fancyuser2 teamuser1 teamuser2 --ignore-not-found
# Only the LDAP-provider identities - not --all, which would also delete
# htpasswd:admin along with them and break admin's OAuth login until the
# Identity is recreated. Identity names are "ldap:<base64 of the user's DN>",
# not "ldap:<username>", so they have to be matched by prefix rather than
# listed by name.
oc get identity -o name | grep '^identity.user.openshift.io/ldap:' | xargs -r oc delete --ignore-not-found
oc delete group ose-fancy-dev ose-normal-dev ose-teamed-app ose-user --ignore-not-found

# Remove RBAC bindings
oc adm policy remove-cluster-role-from-user cluster-admin fancyuser1 2>/dev/null || true
oc adm policy remove-cluster-role-from-group cluster-reader ose-fancy-dev 2>/dev/null || true

# The authentication operator applies the OAuth change above in several
# stages (trust bundle sync, cert rotation, etc.), and oauth-openshift can
# roll out more than once in a row as a result. We wait for full, sustained
# stability *before* tearing down glauth below - not just so the attendee's
# Console tab is safe to touch (see configure-oauth-ldap.sh), but because the
# old LDAP-configured oauth-openshift pods can still be running and trying to
# reach glauth while the rollout is in progress. Deleting glauth first (the
# previous order) left a window where those still-running old pods got
# connection failures against an already-deleted LDAP server.
echo "Waiting for OAuth to fully stabilize before tearing down glauth - do NOT log back in to or reload the OCP Console tab until this finishes."
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
    echo "WARNING: Timed out after ${MAX_WAIT_SECS}s waiting for OAuth to stabilize - continuing to delete glauth anyway, but check 'oc get co authentication' and 'oc get pods -n openshift-authentication'"
    break
  fi
done

# Now safe to remove the client secret/CA config, the LDAP server, and test projects.
oc delete secret ldap-secret -n openshift-config --ignore-not-found
oc delete configmap ca-config-map -n openshift-config --ignore-not-found
echo "Deleting test projects and the glauth LDAP server - this can take a minute or two..."
oc delete project app-dev app-test app-prod glauth --ignore-not-found --timeout=180s \
  || echo "WARNING: project deletion did not finish within 180s - it will keep terminating in the background, this is not a safety concern on its own"

# "oc get co authentication" only reports the state of the oauth-openshift
# Deployment itself - it says nothing about whether the public oauth and
# console routes (which is what a real login/reload actually hits) have
# caught up. Measured live: the operator can report fully stable while the
# oauth route still returns brief connection failures for several more
# seconds - exactly the window a login racing this script's "safe" message
# would land in and freeze. Confirm the real routes are reachable too before
# telling the attendee it's safe to log back in.
wait_for_route_reachable() {
  local url="$1" label="$2"
  local required_ok=10 max_wait=120 ok_streak=0 elapsed=0
  while :; do
    local code
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ] || [ "$code" = "403" ]; then
      ok_streak=$((ok_streak+1))
    else
      [ "$ok_streak" -gt 0 ] && echo "  $label returned $code - resetting reachability streak"
      ok_streak=0
    fi
    [ "$ok_streak" -ge "$required_ok" ] && return 0
    sleep 1; elapsed=$((elapsed+1))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "WARNING: $label did not stay reachable for ${required_ok}s straight within ${max_wait}s - continuing anyway, but logging back in right now may still hit a transient failure"
      return 1
    fi
  done
}

OAUTH_HOST=$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}' 2>/dev/null)
CONSOLE_HOST=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)
echo "Confirming the oauth and console routes are actually reachable before declaring it safe to log back in..."
[ -n "$OAUTH_HOST" ] && wait_for_route_reachable "https://${OAUTH_HOST}/healthz" "oauth route"
[ -n "$CONSOLE_HOST" ] && wait_for_route_reachable "https://${CONSOLE_HOST}/" "console route"

echo "Cleanup complete - it is now safe to continue to the next module"
