#!/usr/bin/env bash
# Shared helpers for MaaS debugging scripts.
# Shell: bash. Requires: oc or kubectl, curl, python3 (most scripts), jq (some).

set -euo pipefail

KUBECTL="${KUBECTL:-}"
if [[ -z "$KUBECTL" ]]; then
  if command -v oc >/dev/null 2>&1; then
    KUBECTL=oc
  else
    KUBECTL=kubectl
  fi
fi

GW_NS="${GW_NS:-openshift-ingress}"
GW_NAME="${GW_NAME:-maas-default-gateway}"
EF_NS="${EF_NS:-$GW_NS}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

gateway_pod() {
  local ns="${1:-$GW_NS}"
  local name="${2:-$GW_NAME}"
  local pod
  pod="$("$KUBECTL" get pod -n "$ns" \
    -l "gateway.networking.k8s.io/gateway-name=${name}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || die "no Running pod for Gateway/${name} in ${ns}"
  echo "$pod"
}

cluster_domain() {
  "$KUBECTL" get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}' 2>/dev/null || true
}

# Resolve MaaS gateway HTTPS hostname.
# Prefer MAAS_GATEWAY_HOST (with or without https://), else Gateway listener, else maas.<cluster-domain>.
maas_host() {
  local host=""
  if [[ -n "${MAAS_GATEWAY_HOST:-}" ]]; then
    host="${MAAS_GATEWAY_HOST#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    echo "https://${host}"
    return
  fi

  host="$("$KUBECTL" get gateway "$GW_NAME" -n "$GW_NS" \
    -o jsonpath='{.spec.listeners[?(@.protocol=="HTTPS")].hostname}' 2>/dev/null \
    | awk '{print $1}')"
  if [[ -n "$host" ]]; then
    echo "https://${host}"
    return
  fi

  local domain
  domain="$(cluster_domain)"
  [[ -n "$domain" ]] || die "could not resolve MAAS host; set MAAS_GATEWAY_HOST=https://maas.apps...."
  echo "https://maas.${domain}"
}

detect_maas_api_ns() {
  if [[ -n "${MAAS_API_NS:-}" ]]; then
    echo "$MAAS_API_NS"
    return
  fi
  if "$KUBECTL" get ns redhat-ai-gateway-infra >/dev/null 2>&1; then
    echo "redhat-ai-gateway-infra"
  elif "$KUBECTL" get ns odh-ai-gateway-infra >/dev/null 2>&1; then
    echo "odh-ai-gateway-infra"
  elif "$KUBECTL" get ns redhat-ods-applications >/dev/null 2>&1; then
    echo "redhat-ods-applications"
  elif "$KUBECTL" get ns opendatahub >/dev/null 2>&1; then
    echo "opendatahub"
  else
    die "could not detect MaaS API namespace; set MAAS_API_NS"
  fi
}

oc_token() {
  if [[ -n "${OC_TOKEN:-}" ]]; then
    echo "$OC_TOKEN"
    return
  fi
  if [[ "$KUBECTL" == "oc" ]]; then
    oc whoami -t
  else
    die "set OC_TOKEN (kubectl has no whoami -t)"
  fi
}

# Port-forward Envoy admin :15000, run a callback, then tear down.
# Usage: with_envoy_admin <pod> <ns> <bash function name>
# The function receives LOCAL_ADMIN_PORT as $1.
with_envoy_admin() {
  local pod="$1" ns="$2" fn="$3"
  local local_port="${ENVOY_ADMIN_PORT:-15000}"
  local pf_log pf_pid
  pf_log="$(mktemp)"
  cleanup_pf() {
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
    rm -f "$pf_log"
  }
  trap cleanup_pf EXIT

  "$KUBECTL" port-forward -n "$ns" "pod/${pod}" "${local_port}:15000" >"$pf_log" 2>&1 &
  pf_pid=$!

  local i
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${local_port}/ready" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  curl -fsS "http://127.0.0.1:${local_port}/ready" >/dev/null 2>&1 \
    || die "Envoy admin not ready on ${pod} (see ${pf_log})"

  "$fn" "$local_port"
  cleanup_pf
  trap - EXIT
}

# --- Postgres / MaaS DB helpers ---------------------------------------------

POSTGRES_DEPLOY="${POSTGRES_DEPLOY:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-maas}"
POSTGRES_DB="${POSTGRES_DB:-maas}"

# Resolve namespace hosting deployment/postgres.
# Order: DB_NS → MAAS_API_NS → cluster-wide lookup of deploy/postgres.
detect_db_ns() {
  if [[ -n "${DB_NS:-}" ]]; then
    echo "$DB_NS"
    return
  fi
  if [[ -n "${MAAS_API_NS:-}" ]] && "$KUBECTL" get deploy "$POSTGRES_DEPLOY" -n "$MAAS_API_NS" >/dev/null 2>&1; then
    echo "$MAAS_API_NS"
    return
  fi

  local candidates=(
    redhat-ai-gateway-infra
    odh-ai-gateway-infra
    redhat-ods-applications
    opendatahub
  )
  local ns
  for ns in "${candidates[@]}"; do
    if "$KUBECTL" get deploy "$POSTGRES_DEPLOY" -n "$ns" >/dev/null 2>&1; then
      echo "$ns"
      return
    fi
  done

  # Cluster-wide last resort (first hit)
  ns="$("$KUBECTL" get deploy -A -o json 2>/dev/null | python3 -c '
import json,sys
name=sys.argv[1]
for i in json.load(sys.stdin).get("items",[]):
  if i.get("metadata",{}).get("name")==name:
    print(i["metadata"]["namespace"]); break
' "$POSTGRES_DEPLOY" 2>/dev/null || true)"
  [[ -n "$ns" ]] || die "could not find deployment/${POSTGRES_DEPLOY}; set DB_NS"
  echo "$ns"
}

# Run psql inside the Postgres deployment. Extra args passed to psql.
# Usage: db_psql [-c 'SQL'] ...
# Credentials: prefer postgres-creds secret (POSTGRES_USER/DB), else POSTGRES_USER/DB env.
db_psql() {
  local ns user db
  ns="$(detect_db_ns)"
  user="$POSTGRES_USER"
  db="$POSTGRES_DB"
  if "$KUBECTL" get secret postgres-creds -n "$ns" >/dev/null 2>&1; then
    user="$("$KUBECTL" get secret postgres-creds -n "$ns" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d 2>/dev/null || echo "$user")"
    db="$("$KUBECTL" get secret postgres-creds -n "$ns" -o jsonpath='{.data.POSTGRES_DB}' | base64 -d 2>/dev/null || echo "$db")"
  fi
  "$KUBECTL" exec -n "$ns" "deploy/${POSTGRES_DEPLOY}" -- \
    psql -U "$user" -d "$db" "$@"
}

# --- Inference helpers (mint key / resolve model) ---------------------------

# Mint short-lived API key. Sets globals: API_KEY, API_KEY_ID, _MAAS_HOST, _OC_TOKEN_FOR_KEY.
# Caller should trap cleanup_minted_api_key if KEEP_KEY!=1.
mint_api_key() {
  local host name resp body code
  host="$(maas_host)"
  _MAAS_HOST="$host"
  _OC_TOKEN_FOR_KEY="$(oc_token)"
  name="${API_KEY_NAME:-debug-$(date +%s)}"
  resp="$(curl -sSk --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
    -H "Authorization: Bearer ${_OC_TOKEN_FOR_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"expiresIn\":\"1h\",\"name\":\"${name}\"}" \
    "${host}/maas-api/v1/api-keys")"
  body="$(echo "$resp" | sed '$d')"
  code="$(echo "$resp" | tail -n1)"
  [[ "$code" == "201" || "$code" == "200" ]] \
    || die "API key mint failed (HTTP ${code}): $(echo "$body" | head -c 300)"
  API_KEY="$(echo "$body" | jq -r '.key // empty')"
  API_KEY_ID="$(echo "$body" | jq -r '.id // empty')"
  [[ -n "$API_KEY" ]] || die "no .key in mint response"
}

cleanup_minted_api_key() {
  if [[ "${KEEP_KEY:-0}" -eq 0 && -n "${API_KEY_ID:-}" && -n "${_OC_TOKEN_FOR_KEY:-}" && -n "${_MAAS_HOST:-}" ]]; then
    curl -sSk -o /dev/null -X DELETE \
      -H "Authorization: Bearer ${_OC_TOKEN_FOR_KEY}" \
      "${_MAAS_HOST}/maas-api/v1/api-keys/${API_KEY_ID}" 2>/dev/null || true
    info "deleted API key ${API_KEY_ID}"
  fi
}

# Resolve MODEL_NAME + MODEL_URL from /maas-api/v1/models using API_KEY.
# Optional arg: requested model id.
resolve_model() {
  local host requested models model_path
  host="$(maas_host)"
  requested="${1:-}"
  [[ -n "${API_KEY:-}" ]] || die "API_KEY required before resolve_model"
  models="$(curl -sSk --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H 'Content-Type: application/json' \
    "${host}/maas-api/v1/models")"
  if [[ -n "$requested" ]]; then
    MODEL_NAME="$(echo "$models" | jq -r --arg m "$requested" '.data[]? | select(.id==$m) | .id' | head -1)"
    MODEL_URL="$(echo "$models" | jq -r --arg m "$requested" '.data[]? | select(.id==$m) | .url' | head -1)"
  else
    MODEL_NAME="$(echo "$models" | jq -r '.data[0].id // empty')"
    MODEL_URL="$(echo "$models" | jq -r '.data[0].url // empty')"
  fi
  [[ -n "$MODEL_NAME" && "$MODEL_NAME" != "null" ]] || die "no models available (requested=${requested:-first})"
  [[ -n "$MODEL_URL" && "$MODEL_URL" != "null" ]] || die "model has no url"
  if grep -q '\.svc\.cluster\.local' <<<"$MODEL_URL"; then
    model_path="$(echo "$MODEL_URL" | sed 's|https\?://[^/]*||')"
    MODEL_URL="${host}${model_path}"
    info "rewrote internal model URL → ${MODEL_URL}"
  fi
}

# Heuristic: is this an llm-d-inference-sim / sample simulator model?
is_simulator_model() {
  local name="${1:-${MODEL_NAME:-}}"
  [[ "$name" =~ [Ss]im ]] || [[ "$name" =~ simulator ]] || [[ "$name" =~ llm-simulator ]] \
    || [[ "$name" =~ facebook/opt-125m ]] || [[ "$name" =~ opt-125m ]]
}

# Ensure API_KEY is set (mint if needed). Sets KEEP_KEY-aware cleanup trap if minted.
ensure_api_key() {
  if [[ -n "${API_KEY:-}" ]]; then
    info "Using API_KEY from env (skip mint)"
    return
  fi
  info "Minting API key"
  mint_api_key
  trap cleanup_minted_api_key EXIT
  ok "minted key id=${API_KEY_ID}"
}
