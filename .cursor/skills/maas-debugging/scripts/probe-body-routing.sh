#!/usr/bin/env bash
# A/B probe: body-only chat/completions vs same request with X-Gateway-Model-Name.
#
# If with-header works and body-only 404s → ipp-pre / model→header missing from live chain.
#
# Usage:
#   ./scripts/probe-body-routing.sh publishers/llm/models/my-model
#   MODEL=llm-simulator ./scripts/probe-body-routing.sh
#   API_KEY=sk-... ./scripts/probe-body-routing.sh my-model
#
# Source: personal-knowledge-base/maas/gateway-debugging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 [MODEL_ID]

Send the same /v1/chat/completions request twice:
  1) body-only (model in JSON)
  2) body + X-Gateway-Model-Name header (control)

Env:
  MODEL / MODEL_ID     Model id (arg wins)
  API_KEY / OC_TOKEN   Auth (default: oc whoami -t)
  MAAS_GATEWAY_HOST    Override gateway URL
  MAX_TOKENS           Default 8
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

MODEL_ID="${1:-${MODEL:-${MODEL_ID:-}}}"
[[ -n "$MODEL_ID" ]] || die "MODEL_ID required (arg or MODEL=...)"

require_cmd curl

HOST="$(maas_host)"
TOKEN="${API_KEY:-$(oc_token)}"
MAX_TOKENS="${MAX_TOKENS:-8}"
BODY="$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"hi"}],"max_tokens":int(sys.argv[2])}))' "$MODEL_ID" "$MAX_TOKENS")"

info "HOST=${HOST}"
info "MODEL=${MODEL_ID}"

echo
info "1) body-only (expect 404 if IPP/pre missing)"
curl -sSk --http1.1 -o /tmp/maas-probe-body.txt -w 'body-only HTTP %{http_code}\n' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  "${HOST}/v1/chat/completions" \
  --max-time 60 || true
head -c 400 /tmp/maas-probe-body.txt; echo

echo
info "2) body + X-Gateway-Model-Name (control)"
curl -sSk --http1.1 -o /tmp/maas-probe-hdr.txt -w 'with-header HTTP %{http_code}\n' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -H "X-Gateway-Model-Name: ${MODEL_ID}" \
  -d "$BODY" \
  "${HOST}/v1/chat/completions" \
  --max-time 60 || true
head -c 400 /tmp/maas-probe-hdr.txt; echo

echo
echo "Interpretation: header OK + body 404 ⇒ missing/broken ipp-pre in live Envoy chain."
echo "Next: ./scripts/print-envoy-filters.sh"
