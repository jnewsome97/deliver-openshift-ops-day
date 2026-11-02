#!/bin/bash
set -euo pipefail

KEYCLOAK_URL=$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')

GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

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

echo "Console is ready - it is now safe to log in as developer1"
