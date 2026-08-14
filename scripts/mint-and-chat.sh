#!/usr/bin/env bash
# Mint a MaaS API key (via OC token), list models, run a chat/completions call.
#
# Usage:
#   ./scripts/mint-and-chat.sh
#   ./scripts/mint-and-chat.sh llm-simulator
#   ./scripts/mint-and-chat.sh --endpoint completions
#   MAAS_GATEWAY_HOST=https://maas.apps.... ./scripts/mint-and-chat.sh
#
# Sources: today's Praxis validate path + maas-billing/scripts/validate-deployment.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ENDPOINT="chat/completions"
REQUESTED_MODEL=""
MAX_TOKENS="${MAX_TOKENS:-50}"
KEEP_KEY=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [MODEL_NAME]

  1. Mint API key with OC token (POST /maas-api/v1/api-keys)
  2. List models (GET /maas-api/v1/models)
  3. POST /v1/<endpoint> against the model URL

Options:
  --endpoint NAME     chat/completions (default) | completions | responses
  --keep-key          Do not DELETE the minted key on exit
  -h, --help          Help

Env:
  MAAS_GATEWAY_HOST   Override gateway URL
  OC_TOKEN            Override oc whoami -t
  MAX_TOKENS          Default 50
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --keep-key) KEEP_KEY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown arg: $1" ;;
    *) REQUESTED_MODEL="$1"; shift ;;
  esac
done

require_cmd curl jq

HOST="$(maas_host)"
OC_TOKEN_VAL="$(oc_token)"
API_KEY_NAME="debug-$(date +%s)"
API_KEY=""
API_KEY_ID=""

cleanup() {
  if [[ "$KEEP_KEY" -eq 0 && -n "$API_KEY_ID" ]]; then
    curl -sSk -o /dev/null -X DELETE \
      -H "Authorization: Bearer ${OC_TOKEN_VAL}" \
      "${HOST}/maas-api/v1/api-keys/${API_KEY_ID}" 2>/dev/null || true
    info "deleted API key ${API_KEY_ID}"
  fi
}
trap cleanup EXIT

info "HOST=${HOST}"
info "Minting API key name=${API_KEY_NAME}"

KEY_RESP="$(curl -sSk --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
  -H "Authorization: Bearer ${OC_TOKEN_VAL}" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "{\"expiresIn\":\"1h\",\"name\":\"${API_KEY_NAME}\"}" \
  "${HOST}/maas-api/v1/api-keys")"
KEY_BODY="$(echo "$KEY_RESP" | sed '$d')"
KEY_CODE="$(echo "$KEY_RESP" | tail -n1)"
echo "mint HTTP ${KEY_CODE}"
echo "$KEY_BODY" | jq . 2>/dev/null || echo "$KEY_BODY"

[[ "$KEY_CODE" == "201" || "$KEY_CODE" == "200" ]] \
  || die "API key mint failed (common: AuthPolicy / X-MaaS-Username / Authorino). Check ./scripts/check-auth-stack.sh"

API_KEY="$(echo "$KEY_BODY" | jq -r '.key // empty')"
API_KEY_ID="$(echo "$KEY_BODY" | jq -r '.id // empty')"
[[ -n "$API_KEY" ]] || die "no .key in mint response"

echo
info "Listing models"
MODELS_RESP="$(curl -sSk --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  "${HOST}/maas-api/v1/models")"
MODELS_BODY="$(echo "$MODELS_RESP" | sed '$d')"
MODELS_CODE="$(echo "$MODELS_RESP" | tail -n1)"
echo "models HTTP ${MODELS_CODE}"
echo "$MODELS_BODY" | jq . 2>/dev/null || echo "$MODELS_BODY"

MODEL_NAME=""
MODEL_URL=""
if [[ -n "$REQUESTED_MODEL" ]]; then
  MODEL_NAME="$(echo "$MODELS_BODY" | jq -r --arg m "$REQUESTED_MODEL" '.data[]? | select(.id==$m) | .id' | head -1)"
  MODEL_URL="$(echo "$MODELS_BODY" | jq -r --arg m "$REQUESTED_MODEL" '.data[]? | select(.id==$m) | .url' | head -1)"
else
  MODEL_NAME="$(echo "$MODELS_BODY" | jq -r '.data[0].id // empty')"
  MODEL_URL="$(echo "$MODELS_BODY" | jq -r '.data[0].url // empty')"
fi

[[ -n "$MODEL_NAME" && "$MODEL_NAME" != "null" ]] || die "no models available (deploy a sample model first)"
[[ -n "$MODEL_URL" && "$MODEL_URL" != "null" ]] || die "model has no url"

if grep -q '\.svc\.cluster\.local' <<<"$MODEL_URL"; then
  MODEL_PATH="$(echo "$MODEL_URL" | sed 's|https\?://[^/]*||')"
  MODEL_URL="${HOST}${MODEL_PATH}"
  info "rewrote internal model URL → ${MODEL_URL}"
fi

CHAT_URL="${MODEL_URL%/}/v1/${ENDPOINT}"
case "$ENDPOINT" in
  chat/completions)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --argjson t "$MAX_TOKENS" \
      '{model:$m, messages:[{role:"user",content:"Hello"}], max_tokens:$t}')"
    ;;
  completions)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --argjson t "$MAX_TOKENS" \
      '{model:$m, prompt:"Hello", max_tokens:$t}')"
    ;;
  responses)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --argjson t "$MAX_TOKENS" \
      '{model:$m, input:"Hello", max_tokens:$t}')"
    ;;
  *)
    die "unsupported --endpoint: $ENDPOINT"
    ;;
esac

echo
info "Inference: POST ${CHAT_URL}"
INF_RESP="$(curl -sSk --connect-timeout 10 --max-time 60 -w '\n%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST -d "$PAYLOAD" \
  "$CHAT_URL")"
INF_BODY="$(echo "$INF_RESP" | sed '$d')"
INF_CODE="$(echo "$INF_RESP" | tail -n1)"
echo "inference HTTP ${INF_CODE}"
echo "$INF_BODY" | jq . 2>/dev/null || echo "$INF_BODY"

[[ "$INF_CODE" == "200" ]] || exit 1
ok "generation succeeded for model=${MODEL_NAME}"
