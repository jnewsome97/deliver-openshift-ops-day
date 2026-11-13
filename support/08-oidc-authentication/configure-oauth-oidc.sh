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

KEYCLOAK_URL=$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')

GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

_set_acm_mce_console_enabled false

cat <<EOF | oc apply -f -
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
  - name: rhbk
    mappingMethod: claim
    type: OpenID
    openID:
      clientID: openshift
      clientSecret:
        name: rhbk-client-secret
      issuer: https://${KEYCLOAK_URL}/realms/OpenShift
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      extraScopes:
      - email
      - profile
EOF

echo "Waiting for OAuth operator to pick up the config change..."
ELAPSED=0
until [ "$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$GEN")" != "$GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 60 ] && echo "Warning: OAuth operator slow to pick up config change - continuing to wait below" && break
done

# The authentication operator applies this change in several stages (trust
# bundle sync, cert rotation, etc.), and oauth-openshift can roll out more
# than once in a row as a result - observed live to take 6 sequential
# rollouts over ~14 minutes. Declaring success after the first rollout
# finishes is not safe: logging out / reloading the Console while a later
# restart is still in flight causes repeated auth failures against the
# Console's open API watches, which can freeze the Console tab's browser
# tab. "oc rollout status" already knows how to wait for one rollout to
# finish; the only thing we need on top is to notice if another one starts
# right after, and wait again.
echo "Waiting for OAuth to fully stabilize - do NOT log out of or reload the OCP Console tab until this finishes."
MAX_WAIT_SECS=1200
SETTLE_SECS=30
SECONDS=0

while :; do
  REMAINING=$((MAX_WAIT_SECS - SECONDS))
  if [ "$REMAINING" -le 0 ] || ! oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout="${REMAINING}s"; then
    echo "ERROR: oauth-openshift did not finish rolling out within ${MAX_WAIT_SECS}s total."
    echo "Do NOT log out of or reload the OCP Console tab yet. Check 'oc get co authentication' and 'oc get pods -n openshift-authentication', then re-run this script once it settles."
    exit 1
  fi
  GEN_AFTER=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
  sleep "$SETTLE_SECS"
  GEN_NOW=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
  [ "$GEN_AFTER" = "$GEN_NOW" ] && break
  echo "  oauth-openshift restarted again (generation $GEN_AFTER -> $GEN_NOW) - this is expected, waiting for it to finish too"
done

# "oc rollout status" / "oc get co authentication" only report the state of
# the oauth-openshift Deployment itself - they say nothing about whether the
# public oauth and console routes (what a real login/reload actually hits)
# have caught up. Measured live: the operator can report fully stable while
# the oauth route still returns brief connection failures for several more
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

echo "OAuth is live with rhbk provider and has been stable - it is now safe to log out and reload the console"

# developer1 is about to log in for the very first time. With no
# console.lastPerspective preference yet set for them, and the acm console
# plugin enabled, OpenShift Console defaults brand-new users straight into
# the ACM Fleet-management (multicloud) overview - which runs a 5s
# operator-health poll plus an all-namespaces Events walk that has been
# observed to pin a Console tab's renderer in a GC-thrashing freeze, in both
# the embedded Showroom tab and a plain external browser tab. Temporarily
# disable the acm perspective so developer1's first login lands on the
# lightweight single-cluster Administrator view instead.
# cleanup-oidc.sh restores whatever was here before.
echo "Temporarily disabling the ACM Fleet-management console perspective so developer1's first login doesn't land there..."
PERSPECTIVES_FILE=/tmp/.oidc-orig-perspectives.json
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.customization.perspectives}' > "$PERSPECTIVES_FILE" 2>/dev/null
[ -s "$PERSPECTIVES_FILE" ] || echo '[]' > "$PERSPECTIVES_FILE"
PATCH=$(python3 -c '
import json
with open("'"$PERSPECTIVES_FILE"'") as f:
    perspectives = json.load(f)
if not any(p.get("id") == "acm" for p in perspectives):
    perspectives.append({"id": "acm", "visibility": {"state": "Disabled"}})
print(json.dumps({"spec": {"customization": {"perspectives": perspectives}}}))
')
oc patch consoles.operator.openshift.io cluster --type=merge -p "$PATCH"

# This also restarts the console deployment (observed as a single-stage
# rollout, unlike oauth-openshift's multi-stage one) - wait it out the same
# way before declaring it safe to log in.
echo "Waiting for the Console to pick up the perspective change and stabilize..."
if ! oc rollout status deployment/console -n openshift-console --timeout=300s; then
  echo "ERROR: console did not finish rolling out within 300s."
  echo "Do NOT log in as developer1 yet. Check 'oc get co console' and 'oc get pods -n openshift-console', then re-run this script once it settles."
  exit 1
fi

echo "Confirming the console route is actually reachable before declaring it safe to log in..."
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

echo "Console is ready - it is now safe to log in as developer1"
