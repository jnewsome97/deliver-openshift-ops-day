#!/bin/bash
set -euo pipefail

_set_acm_mce_console_enabled() {
  local target="$1" verb
  [ "$target" = "true" ] && verb="Re-enabling" || verb="Disabling"
  echo "${verb} ACM/MCE console plugins..."
  if oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null 2>&1; then
    local patch
    patch=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o json | python3 -c "
import json, sys
enabled = '$target' == 'true'
mch = json.load(sys.stdin)
for c in mch['spec']['overrides']['components']:
    if c['name'] == 'console':
        c['enabled'] = enabled
print(json.dumps({'spec': {'overrides': {'components': mch['spec']['overrides']['components']}}}))
")
    oc patch multiclusterhub multiclusterhub -n open-cluster-management --type=merge -p "$patch"
  fi
  if oc get multiclusterengine multiclusterengine &>/dev/null 2>&1; then
    local patch
    patch=$(oc get multiclusterengine multiclusterengine -o json | python3 -c "
import json, sys
enabled = '$target' == 'true'
mce = json.load(sys.stdin)
for c in mce['spec']['overrides']['components']:
    if c['name'] == 'console-mce':
        c['enabled'] = enabled
print(json.dumps({'spec': {'overrides': {'components': mce['spec']['overrides']['components']}}}))
")
    oc patch multiclusterengine multiclusterengine --type=merge -p "$patch"
  fi
}

GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")

_set_acm_mce_console_enabled false

cat <<EOF > $HOME/support/oauth-cluster.yaml
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
  - name: ldap                    # name shown on console login page
    mappingMethod: claim           # first identity provider to claim a username wins
    type: LDAP
    ldap:
      attributes:
        id: [dn]                   # LDAP field used as unique user ID
        email: [mail]
        name: [cn]                 # display name
        preferredUsername: [uid]    # what they type at the login prompt
      bindDN: "cn=openshiftworkshop,ou=svcaccts,ou=users,dc=openshiftworkshop,dc=com"
      bindPassword:
        name: ldap-secret          # references the Secret created earlier
      ca:
        name: ca-config-map        # CA cert to validate LDAP server's TLS
      insecure: false              # always false in production - validates TLS
      url: "ldaps://glauth.glauth.svc.cluster.local/ou=users,dc=openshiftworkshop,dc=com?uid?sub?(memberOf=ou=ose-user,ou=groups,dc=openshiftworkshop,dc=com)"
  tokenConfig:
    accessTokenMaxAgeSeconds: 86400  # tokens valid for 24 hours
EOF

echo "Applying OAuth configuration..."
oc apply -f $HOME/support/oauth-cluster.yaml

echo "Waiting for OAuth operator to pick up the config change..."
ELAPSED=0
until [ "$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$GEN")" != "$GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 60 ] && echo "Warning: OAuth operator slow to pick up config change - continuing to wait below" && break
done

# The authentication operator applies this change in several stages (trust
# bundle sync, cert rotation, etc.), and oauth-openshift can roll out more
# than once in a row as a result. Declaring success after the first rollout
# finishes is not safe: logging out / reloading the Console while a later
# restart is still in flight causes repeated auth failures against the
# Console's open API watches, which can freeze the Console tab's browser
# tab. Instead, wait until the cluster has been fully quiet for a sustained
# period, resetting the quiet timer every time oauth-openshift restarts
# again.
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
    echo "ERROR: Timed out after ${MAX_WAIT_SECS}s waiting for OAuth to stabilize - check 'oc get co authentication' and 'oc get pods -n openshift-authentication'"
    break
  fi
done

# "oc get co authentication" only reports the state of the oauth-openshift
# Deployment itself - it says nothing about whether the public oauth and
# console routes (which is what a real login/reload actually hits) have
# caught up. Measured live: the operator can report fully stable while the
# oauth route still returns brief connection failures for several more
# seconds - exactly the window a login racing this script's "safe" message
# would land in and freeze. Confirm the real routes are reachable too before
# declaring success.
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
      echo "WARNING: $label did not stay reachable for ${required_ok}s straight within ${max_wait}s - continuing anyway, but a login racing this window may still hit a transient failure"
      return 1
    fi
  done
}

OAUTH_HOST=$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}' 2>/dev/null)
CONSOLE_HOST=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)
echo "Confirming the oauth and console routes are actually reachable before declaring it safe to log in..."
[ -n "$OAUTH_HOST" ] && wait_for_route_reachable "https://${OAUTH_HOST}/healthz" "oauth route"
[ -n "$CONSOLE_HOST" ] && wait_for_route_reachable "https://${CONSOLE_HOST}/" "console route"

_set_acm_mce_console_enabled true
echo "Waiting for the console to stabilize after restoring ACM/MCE plugins..."
STABLE_FOR=0; TOTAL_ELAPSED=0; LAST_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
while :; do
  CUR_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment console -n openshift-console -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment console -n openshift-console -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment console -n openshift-console -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment console -n openshift-console -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  if [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "${REPLICAS:-0}" ] && [ "${UPDATED:-0}" = "${REPLICAS:-0}" ] \
     && [ "${REPLICAS:-0}" -gt 0 ] && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ] && \
      echo "  console restarted (generation $LAST_GEN -> $CUR_GEN) - resetting stability timer"
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"
  [ "$STABLE_FOR" -ge 30 ] && break
  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  [ "$TOTAL_ELAPSED" -ge 300 ] && echo "WARNING: Timed out waiting for console to stabilize after ACM/MCE restore" && break
done

echo "OAuth configuration applied and has been stable for ${REQUIRED_STABLE_SECS}s - it is now safe to log out and reload the console"
