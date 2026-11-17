#!/usr/bin/env bash
#
# Setup for the OpenShift Ops Day ACS module.
#
# Deploys the workshop workloads, then configures the RHACS 5 pieces that
# module uses:
#   - file activity monitoring and a deployment file-activity policy
#   - the ACS MCP server, and Lightspeed wiring when OLSConfig already exists
#   - Lightspeed-assisted risk enrichment (Central query access, a Central-only
#     network policy, and ROX_LIGHTSPEED_ENDPOINT)
#
# Does not enable init-container policy evaluation.
#
# Re-run after the Lightspeed module if the first run reports that OLSConfig
# or the Lightspeed operator was missing. Workloads and RHACS settings that
# are already in place are left alone.
#
# Usage (from a bastion that is already logged in with oc; the full run
# also needs ~/demo-applications cloned -- the module's setup step does
# this):
#   ./setup-scripts/acs-config-scripts/setup-acs-module.sh
#
# Pass --mcp-only to skip workload deployment and FAM/policy setup and only
# run the MCP/Lightspeed registration step. Use this for the "register MCP
# after completing the Lightspeed module" case instead of a full re-run --
# a full re-run re-applies the workload manifests, which re-triggers Sensor's
# image-scan backlog for those deployments even though nothing changed.
#   ./setup-scripts/acs-config-scripts/setup-acs-module.sh --mcp-only

set -euo pipefail

# Only needed when deploying workloads. --mcp-only never touches these
# manifests, so the existence check lives in deploy_workloads instead of at
# the top of the script (the module's Lightspeed section runs --mcp-only on
# bastions where the clone may not exist).
readonly ROOT="${DEMO_APPLICATIONS_ROOT:-${HOME}/demo-applications}"

readonly MCP_NAMESPACE="rhacs-mcp"
readonly MCP_DEPLOYMENT="stackrox-mcp"
readonly LIGHTSPEED_NAMESPACE="openshift-lightspeed"
readonly LIGHTSPEED_SECRET="acs-mcp-api-token"
# Exported because the Python helpers read them from the environment.
# A prefix assignment (NAME="${NAME}" cmd) fails when the variable is readonly.
declare -rx TOKEN_NAME="ols-mcp-integration"

ACS_NS=""
CENTRAL_NAME=""
SECURED_NAME=""
LIGHTSPEED_STATUS=""
# Documented RHACS 5.0 default. Empty leaves Central unchanged.
RISK_ENRICHMENT_ENDPOINT=""

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TOKEN_FILE=""
cleanup() {
  [[ -n "${TOKEN_FILE}" ]] && rm -f "${TOKEN_FILE}"
}
trap cleanup EXIT

# oc rejects a non-seekable --patch-file on some versions, so write a temp file.
merge_patch() {
  local file rc=0
  file="$(mktemp)"
  cat > "${file}"
  oc patch "$@" --type=merge --patch-file="${file}" >/dev/null || rc=$?
  rm -f "${file}"
  return "${rc}"
}

require_tools() {
  local missing=()
  local cmd
  for cmd in oc python3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    die "Missing required commands: ${missing[*]}"
  fi
  oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift. Run oc login, then re-run this script."
}

apply_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    oc apply -f "${path}" --recursive
  else
    oc apply -f "${path}"
  fi
}

deploy_workloads() {
  local rel
  [[ -d "${ROOT}" ]] \
    || die "${ROOT} not found. Clone https://github.com/mfosterrox/demo-applications.git first (the module's setup step does this), or set DEMO_APPLICATIONS_ROOT."
  info "Deploying workshop workloads..."
  local -a paths=(
    k8s-deployment-manifests/-namespaces/namespace-emojivoto.yaml
    k8s-deployment-manifests/-namespaces/namespace-apache-struts.yaml
    k8s-deployment-manifests/-namespaces/namespace-dvwa.yaml
    k8s-deployment-manifests/-namespaces/namespace-log4shell.yaml
    k8s-deployment-manifests/-namespaces/namespace-webgoat.yaml
    k8s-deployment-manifests/-namespaces/namespace-patient-portal.yaml
    k8s-deployment-manifests/emojivoto
    k8s-deployment-manifests/apache-struts
    k8s-deployment-manifests/dvwa
    k8s-deployment-manifests/log4shell
    k8s-deployment-manifests/webgoat
    k8s-deployment-manifests/acs-fam-demo
    skupper-demo
  )
  for rel in "${paths[@]}"; do
    [[ -e "${ROOT}/${rel}" ]] || die "Missing ${rel} under ${ROOT}"
    apply_path "${ROOT}/${rel}"
  done
}

detect_acs() {
  if oc get central -n stackrox >/dev/null 2>&1; then
    ACS_NS="stackrox"
  else
    ACS_NS="$(oc get central -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  fi
  [[ -n "${ACS_NS}" ]] || die "No Central resource found. Install RHACS, then re-run this script."
  CENTRAL_NAME="$(oc get central -n "${ACS_NS}" -o jsonpath='{.items[0].metadata.name}')"
  SECURED_NAME="$(oc get securedcluster -n "${ACS_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${SECURED_NAME}" ]] || die "No SecuredCluster resource found in ${ACS_NS}."
  info "Central: ${ACS_NS}/${CENTRAL_NAME}"
  info "Secured cluster: ${ACS_NS}/${SECURED_NAME}"
}

# Read a live object, merge file-activity monitoring and the Lightspeed
# endpoint, and patch only when the object would change.
patch_stackrox_cr() {
  local kind="$1"
  local name="$2"
  local enable_fam="$3"
  local lightspeed_endpoint="${4:-}"
  local result
  result="$(
    oc get "$kind" "$name" -n "${ACS_NS}" -o json | \
      ENABLE_FAM="${enable_fam}" LIGHTSPEED_ENDPOINT="${lightspeed_endpoint}" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
spec = doc.setdefault("spec", {})
patch = {"spec": {}}
changed = False

updates = {}
endpoint = os.environ.get("LIGHTSPEED_ENDPOINT", "")
if endpoint:
    updates["ROX_LIGHTSPEED_ENDPOINT"] = endpoint
if updates:
    customize = spec.get("customize") or {}
    env = list(customize.get("envVars") or [])
    by_name = {item.get("name"): item for item in env if isinstance(item, dict)}
    for key, value in updates.items():
        current = by_name.get(key)
        if current is None:
            env.append({"name": key, "value": value})
            changed = True
        elif current.get("value") != value:
            current["value"] = value
            changed = True
    patch["spec"]["customize"] = {"envVars": env}

if os.environ.get("ENABLE_FAM") == "true":
    per_node = spec.get("perNode") or {}
    fam = (per_node.get("fileActivityMonitoring") or {})
    if fam.get("mode") != "Enabled":
        changed = True
    patch["spec"]["perNode"] = {"fileActivityMonitoring": {"mode": "Enabled"}}

if not changed:
    print("unchanged")
else:
    print("changed")
    json.dump(patch, sys.stdout)
'
  )"
  local status="${result%%$'\n'*}"
  local patch_body="${result#*$'\n'}"
  if [[ "${status}" == "unchanged" ]]; then
    return 0
  fi
  printf '%s' "${patch_body}" | merge_patch "$kind" "$name" -n "${ACS_NS}"
  return 0
}

apply_fam_policy() {
  oc apply -f - <<EOF
apiVersion: config.stackrox.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: deployment-file-activity
  namespace: ${ACS_NS}
spec:
  policyName: Deployment File Activity
  categories:
    - File Activity Monitoring
  lifecycleStages:
    - RUNTIME
  eventSource: DEPLOYMENT_EVENT
  exclusions:
    - deployment:
        scope:
          namespace: openshift-.*
  severity: LOW_SEVERITY
  policySections:
    - sectionName: Rule 1
      policyGroups:
        - fieldName: File Path
          booleanOperator: OR
          values:
            - value: /etc/**/*
  criteriaLocked: false
  mitreVectorsLocked: false
  isDefault: false
EOF
  info "File activity monitoring: Enabled"
}

central_route_host() {
  local host
  host="$(oc get route central -n "${ACS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  oc get route -n "${ACS_NS}" -o json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for item in doc.get("items", []):
    name = item["metadata"]["name"]
    host = (item.get("spec") or {}).get("host", "")
    if "central" in name and host:
        print(host)
        break
'
}

wait_for_central() {
  local host="$1"
  local i
  info "Waiting for Central at https://${host} ..."
  for i in $(seq 1 60); do
    if curl -sk --max-time 10 "https://${host}/v1/ping" >/dev/null; then
      info "Central is ready."
      return 0
    fi
    sleep 10
  done
  warn "Central did not answer /v1/ping in time."
  return 1
}

memory_to_mi() {
  # "2Gi" -> 2048, "512Mi" -> 512, "1048576Ki" -> 1024, bare numbers pass through
  local v="$1"
  case "${v}" in
    *Gi) echo $(( ${v%Gi} * 1024 )) ;;
    *Mi) echo $(( ${v%Mi} )) ;;
    *Ki) echo $(( ${v%Ki} / 1024 )) ;;
    *) echo "${v}" ;;
  esac
}

ensure_scanner_db_resources() {
  # scanner-v4-db OOMKills at the default 2Gi limit while Postgres loads the
  # CVE database on first connect. Observed on event clusters: the DB
  # crashloops for hours, no image scan ever completes, and Central's
  # reprocessor stops retrying until Central itself is restarted. 4Gi is
  # verified stable (the DB settles around 500Mi after the initial load).
  # Idempotent: patches only when the current limit is below 4Gi.
  local current limit_mi
  if ! oc get deployment scanner-v4-db -n "${ACS_NS}" >/dev/null 2>&1; then
    return 0  # scanner v4 not deployed, nothing to size
  fi
  current="$(oc get central "${CENTRAL_NAME}" -n "${ACS_NS}" \
    -o jsonpath='{.spec.scannerV4.db.resources.limits.memory}' 2>/dev/null || true)"
  limit_mi="$(memory_to_mi "${current:-0}")"
  if [[ "${limit_mi}" -ge 4096 ]]; then
    return 0
  fi
  info "Bumping scanner-v4-db memory limit (${current:-unset} -> 4Gi) so it survives the initial CVE database load..."
  oc patch central "${CENTRAL_NAME}" -n "${ACS_NS}" --type merge \
    -p '{"spec":{"scannerV4":{"db":{"resources":{"requests":{"cpu":"500m","memory":"2Gi"},"limits":{"cpu":"1","memory":"4Gi"}}}}}}' >/dev/null
  oc rollout status deployment/scanner-v4-db -n "${ACS_NS}" --timeout=180s >/dev/null
  info "scanner-v4-db is running with the raised memory limit."
}

wait_for_demo_scan_data() {
  # The "Ask Lightspeed about a RHACS finding" section needs CVE data on the
  # log4shell image in Central. /v1/ping going green says nothing about that:
  # on a fresh install Sensor reports every deployment in the cluster and
  # Central's reprocessor has to work through them before the demo images get
  # their data. If scanner-v4-db crashlooped earlier, the reprocessor also
  # stops retrying entirely and only a Central restart clears that backlog.
  # So poll the actual image record (per-image GET: the list endpoint does
  # not include scan data), restart Central once if there is no progress
  # after two minutes, and time out with the manual workaround instead of a
  # false "ready".
  local host password image_name i central_restarted=false
  image_name="quay.io/mfoster/log4shell:0.1.0"
  password="$(read_admin_password)" \
    || { warn "Could not read the ACS admin password; skipping scan verification for ${image_name}."; return 0; }
  host="$(central_route_host || true)"
  if [[ -z "${host}" ]]; then
    warn "Could not resolve the Central route; skipping scan verification for ${image_name}."
    return 0
  fi

  info "Waiting for CVE data on ${image_name} (needed by the Lightspeed section)."
  info "This can take a few minutes on the first run while images are scanned for vulnerabilities."
  for i in $(seq 1 60); do
    if PASSWORD="${password}" CENTRAL_HOST="${host}" IMAGE_NAME="${image_name}" python3 - <<'PY'
import base64, json, os, ssl, sys, urllib.request

password = os.environ["PASSWORD"]
host = os.environ["CENTRAL_HOST"]
image_name = os.environ["IMAGE_NAME"]

try:
    ctx = ssl._create_unverified_context()
    auth = base64.b64encode(f"admin:{password}".encode()).decode()

    req = urllib.request.Request(
        f"https://{host}/v1/images?pagination.limit=1000",
        headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        images = json.loads(resp.read().decode()).get("images", [])

    image_id = None
    for item in images:
        name = item.get("name")
        full = name.get("fullName") if isinstance(name, dict) else str(name)
        if full == image_name:
            image_id = item.get("id")
            break
    if not image_id:
        sys.exit(1)  # image not registered in Central yet

    req = urllib.request.Request(
        f"https://{host}/v1/images/{image_id}",
        headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        doc = json.loads(resp.read().decode())

    scan = doc.get("scan") or {}
    cves = [v.get("cve") for c in scan.get("components", []) for v in c.get("vulns", [])]
    sys.exit(0 if "CVE-2021-44228" in cves else 1)
except Exception:
    # Transient errors (Central restarting, 503s from the route) are
    # expected while the stack settles; just poll again.
    sys.exit(1)
PY
    then
      info "Image scan verified: ${image_name} has CVE data (CVE-2021-44228 present)."
      return 0
    fi

    # Two minutes with no result usually means Central's reprocessor has
    # backed off after earlier failures (e.g. a scanner-v4-db crashloop).
    # One Central restart clears it -- but only once Central is actually
    # stable. The CR patches earlier in this script also roll Central, and
    # restarting again mid-roll just adds delay.
    if [[ "${i}" -ge 12 && "${central_restarted}" == false ]]; then
      if oc rollout status deployment/central -n "${ACS_NS}" --timeout=10s >/dev/null 2>&1; then
        warn "No CVE data after 2 minutes with Central up -- restarting Central once to clear a possible reprocessor backlog..."
        oc rollout restart deployment/central -n "${ACS_NS}" >/dev/null 2>&1 || true
        oc rollout status deployment/central -n "${ACS_NS}" --timeout=180s >/dev/null 2>&1 || true
        central_restarted=true
      fi
    fi
    if (( i % 3 == 0 )); then
      info "Still waiting for CVE data... ($(( i * 10 ))s elapsed)"
    fi
    sleep 10
  done
  warn "Timed out waiting for CVE data on ${image_name}."
  warn "The Lightspeed section of this module may show no vulnerabilities until the image is scanned."
  warn "Manual workaround: force a rescan via Central's API (password from:"
  warn "  oc -n ${ACS_NS} get secret acs-password -o go-template='{{index .data \"password\" | base64decode}}')"
  warn "  curl -sk -u admin:<password> -X POST https://${host}/v1/images/scan -H 'Content-Type: application/json' -d '{\"imageName\":\"${image_name}\",\"force\":true}'"
  return 1
}

read_admin_password() {
  local secret key encoded
  for secret in acs-password central-htpasswd central-admin-password; do
    oc get secret "${secret}" -n "${ACS_NS}" >/dev/null 2>&1 || continue
    for key in password admin-password; do
      encoded="$(oc get secret "${secret}" -n "${ACS_NS}" -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
      if [[ -n "${encoded}" ]]; then
        printf '%s' "${encoded}" | python3 -c 'import sys,base64; data=base64.b64decode(sys.stdin.read().strip()); sys.stdout.buffer.write(data.rstrip(b"\n"))'
        return 0
      fi
    done
  done
  return 1
}

generate_api_token() {
  local host="$1"
  local token_file="$2"
  local password
  password="$(read_admin_password)" || return 1
  PASSWORD="${password}" CENTRAL_HOST="${host}" TOKEN_PATH="${token_file}" \
    python3 - <<'PY'
import base64, json, os, ssl, sys, urllib.request
password = os.environ["PASSWORD"]
host = os.environ["CENTRAL_HOST"]
token_name = os.environ["TOKEN_NAME"]
token_path = os.environ["TOKEN_PATH"]
ctx = ssl._create_unverified_context()
auth = base64.b64encode(f"admin:{password}".encode()).decode()

def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"https://{host}{path}",
        data=data,
        method=method,
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw.strip() else {}

listing = request("GET", "/v1/apitokens")
for item in listing.get("tokens") or []:
    if item.get("name") == token_name and not item.get("revoked", False):
        request("PATCH", f"/v1/apitokens/revoke/{item['id']}")
        break

created = request("POST", "/v1/apitokens/generate", {"name": token_name, "roles": ["Analyst"]})
token = created.get("token")
if not token:
    print("Central did not return an API token.", file=sys.stderr)
    print(json.dumps({k: v for k, v in created.items() if k != "token"}), file=sys.stderr)
    sys.exit(1)
with open(token_path, "w", encoding="utf-8") as handle:
    handle.write(token)
os.chmod(token_path, 0o600)
PY
}

deploy_mcp() {
  local token_file="$1"
  # stackrox-mcp dials this as a gRPC target and appends its own default
  # port, so a value with a URL scheme and explicit port (e.g.
  # "https://central.stackrox.svc:443") becomes
  # "https://central.stackrox.svc:443:443" ("too many colons in address").
  # It must be a bare host:port, no scheme.
  local central_url="central.${ACS_NS}.svc:443"
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
EOF
  oc create secret generic stackrox-mcp-api-token -n "${MCP_NAMESPACE}" \
    --from-file=token="${token_file}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: stackrox-mcp
  namespace: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stackrox-mcp-config
  namespace: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
data:
  config.yaml: |
    central:
      url: "${central_url}"
      auth_type: "static"
      insecure_skip_tls_verify: true
      force_http1: false
      request_timeout: "30s"
      max_retries: 3
      initial_backoff: "1s"
      max_backoff: "10s"
    global:
      read_only_tools: true
    server:
      type: "streamable-http"
      address: "0.0.0.0"
      port: 8080
    tools:
      vulnerability:
        enabled: true
      config_manager:
        enabled: true
---
apiVersion: v1
kind: Service
metadata:
  name: stackrox-mcp
  namespace: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: stackrox-mcp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stackrox-mcp
  namespace: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: stackrox-mcp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stackrox-mcp
    spec:
      serviceAccountName: stackrox-mcp
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: stackrox-mcp
          image: quay.io/stackrox-io/mcp:latest
          imagePullPolicy: IfNotPresent
          args: ["--config", "/config/config.yaml"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: STACKROX_MCP__CENTRAL__AUTH_TYPE
              value: static
            - name: STACKROX_MCP__CENTRAL__API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: stackrox-mcp-api-token
                  key: token
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 200m
              memory: 500Mi
            limits:
              memory: 500Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: stackrox-mcp-config
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: stackrox-mcp
  namespace: ${MCP_NAMESPACE}
  labels:
    app.kubernetes.io/name: stackrox-mcp
  annotations:
    haproxy.router.openshift.io/balance: source
spec:
  to:
    kind: Service
    name: stackrox-mcp
    port:
      targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
  oc rollout restart "deployment/${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" >/dev/null
  if ! oc rollout status "deployment/${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" --timeout=180s; then
    warn "ACS MCP server is not ready yet. Check: oc get pods -n ${MCP_NAMESPACE}"
  fi
  info "ACS MCP server: ${MCP_NAMESPACE}/${MCP_DEPLOYMENT}"
}

patch_lightspeed() {
  local token_file="$1"
  local mcp_url="http://${MCP_DEPLOYMENT}.${MCP_NAMESPACE}.svc:8080/mcp"
  if ! oc get namespace "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1; then
    LIGHTSPEED_STATUS="Lightspeed: namespace ${LIGHTSPEED_NAMESPACE} not found; re-run this script after the Lightspeed module"
    info "${LIGHTSPEED_STATUS}"
    return 0
  fi
  oc create secret generic "${LIGHTSPEED_SECRET}" -n "${LIGHTSPEED_NAMESPACE}" \
    --from-literal=header="Bearer $(cat "${token_file}")" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  local scope_args=()
  if oc get olsconfig cluster >/dev/null 2>&1; then
    scope_args=()
  elif oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1; then
    scope_args=(-n "${LIGHTSPEED_NAMESPACE}")
  else
    LIGHTSPEED_STATUS="Lightspeed: OLSConfig not found; re-run this script after the Lightspeed module"
    info "${LIGHTSPEED_STATUS}"
    return 0
  fi

  local result
  result="$(
    oc get olsconfig cluster ${scope_args[@]+"${scope_args[@]}"} -o json | MCP_URL="${mcp_url}" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
spec = doc.get("spec") or {}
gates = list(spec.get("featureGates") or [])
if "MCPServer" not in gates:
    gates.append("MCPServer")
servers = [item for item in (spec.get("mcpServers") or []) if not (isinstance(item, dict) and item.get("name") == "acs-mcp")]
servers.append({
    "name": "acs-mcp",
    "url": os.environ["MCP_URL"],
    "timeout": 120,
    "headers": [{
        "name": "Authorization",
        "valueFrom": {"type": "secret", "secretRef": {"name": "acs-mcp-api-token"}},
    }],
})
previous_gates = list(spec.get("featureGates") or [])
previous_servers = spec.get("mcpServers") or []
changed = previous_gates != gates or json.dumps(previous_servers, sort_keys=True) != json.dumps(servers, sort_keys=True)
sys.stdout.write("changed\n" if changed else "unchanged\n")
json.dump({"spec": {"featureGates": gates, "mcpServers": servers}}, sys.stdout)
'
  )"
  local status="${result%%$'\n'*}"
  local patch_body="${result#*$'\n'}"
  if [[ "${status}" == "changed" ]]; then
    printf '%s' "${patch_body}" | merge_patch olsconfig cluster ${scope_args[@]+"${scope_args[@]}"}
    if oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1; then
      info "Restarting Lightspeed so it reloads the ACS MCP server."
      oc rollout restart deployment/lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null || \
        warn "Could not restart lightspeed-app-server."
    fi
  fi
  LIGHTSPEED_STATUS="Lightspeed: OLSConfig updated with acs-mcp"
  info "${LIGHTSPEED_STATUS}"
}

configure_lightspeed_risk_enrichment() {
  local role="lightspeed-operator-query-access"
  local binding="central-lightspeed-query-access"
  local policy="allow-rhacs-central-lightspeed"
  local ns="${LIGHTSPEED_NAMESPACE}"
  local sa port app_name
  if ! oc get clusterrole "${role}" >/dev/null 2>&1; then
    info "Lightspeed risk enrichment: skipped (OpenShift Lightspeed is not installed). Re-run this script after the Lightspeed module."
    return 0
  fi
  if ! oc get svc lightspeed-app-server -n "${ns}" >/dev/null 2>&1; then
    info "Lightspeed risk enrichment: skipped (lightspeed-app-server is not ready). Re-run this script after the Lightspeed module."
    return 0
  fi
  port="$(oc get svc lightspeed-app-server -n "${ns}" -o jsonpath='{.spec.ports[?(@.port==8443)].port}' 2>/dev/null || true)"
  if [[ -z "${port}" ]]; then
    port="$(oc get svc lightspeed-app-server -n "${ns}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  fi
  port="${port:-8443}"
  RISK_ENRICHMENT_ENDPOINT="https://lightspeed-app-server.${ns}.svc:${port}"

  sa="$(oc get deploy central -n "${ACS_NS}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
  sa="${sa:-central}"
  oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${binding}
  labels:
    app.kubernetes.io/part-of: lightspeed-operator
    app.kubernetes.io/component: rhacs-risk-enrichment
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${role}
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: ${ACS_NS}
EOF

  app_name="$(oc get deploy lightspeed-app-server -n "${ns}" -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || true)"
  if [[ -z "${app_name}" ]]; then
    app_name="$(oc get svc lightspeed-app-server -n "${ns}" -o jsonpath='{.spec.selector.app\.kubernetes\.io/name}' 2>/dev/null || true)"
  fi
  app_name="${app_name:-lightspeed-app-server}"
  # RHACS 5.0 requires a policy that admits only Central. Other clients stay
  # on the network policy the Lightspeed operator already created.
  oc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${policy}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: lightspeed-operator
    app.kubernetes.io/component: rhacs-risk-enrichment
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${app_name}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${ACS_NS}
          podSelector:
            matchLabels:
              app: central
      ports:
        - protocol: TCP
          port: ${port}
EOF
  info "Lightspeed risk enrichment: enabled"
}

configure_mcp_and_lightspeed() {
  local host
  host="$(central_route_host || true)"
  if [[ -z "${host}" ]]; then
    warn "Could not find the Central route in ${ACS_NS}. MCP setup was skipped."
    info "ACS MCP server: skipped (Central route not found)"
    return 0
  fi
  if ! wait_for_central "${host}"; then
    info "ACS MCP server: skipped (Central was not ready)"
    return 0
  fi
  TOKEN_FILE="$(mktemp)"
  chmod 600 "${TOKEN_FILE}"
  if ! generate_api_token "${host}" "${TOKEN_FILE}"; then
    warn "Could not generate a Central API token. MCP setup was skipped."
    info "ACS MCP server: skipped (API token was not created)"
    return 0
  fi
  deploy_mcp "${TOKEN_FILE}"
  patch_lightspeed "${TOKEN_FILE}"
}

main() {
  local mcp_only=false
  if [[ "${1:-}" == "--mcp-only" ]]; then
    mcp_only=true
  fi

  require_tools
  if [[ "${mcp_only}" == false ]]; then
    deploy_workloads
  fi
  detect_acs
  configure_lightspeed_risk_enrichment
  if [[ "${mcp_only}" == false ]]; then
    ensure_scanner_db_resources \
      || warn "Could not bump scanner-v4-db resources; continuing anyway."
    info "Updating Central and Sensor..."
    patch_stackrox_cr central "${CENTRAL_NAME}" false "${RISK_ENRICHMENT_ENDPOINT}"
    patch_stackrox_cr securedcluster "${SECURED_NAME}" true
    apply_fam_policy
  fi
  configure_mcp_and_lightspeed
  if [[ "${mcp_only}" == false ]]; then
    wait_for_demo_scan_data || true
  fi
}

main "$@"
