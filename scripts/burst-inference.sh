#!/usr/bin/env bash
# Burst inference calls with a running token tally after each request.
#
# Similar to maas-billing validate-deployment / verify-models-and-limits rate-limit
# loops, but prints per-call usage AND cumulative totals (from response .usage).
#
# Usage:
#   ./scripts/burst-inference.sh
#   ./scripts/burst-inference.sh llm-simulator --count 20
#   ./scripts/burst-inference.sh --count 10 --delay 0.2 --max-tokens 30
#   API_KEY=sk-... ./scripts/burst-inference.sh my-model --count 15
#   ./scripts/burst-inference.sh --stop-on-429 --count 50
#
# Env:
#   MAAS_GATEWAY_HOST, OC_TOKEN, API_KEY, MAX_TOKENS, COUNT, DELAY_SECS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ENDPOINT="chat/completions"
REQUESTED_MODEL=""
COUNT="${COUNT:-10}"
DELAY_SECS="${DELAY_SECS:-0.3}"
MAX_TOKENS="${MAX_TOKENS:-50}"
STOP_ON_429=0
KEEP_KEY=0
PROMPT="${PROMPT:-Hello}"
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [MODEL_NAME]

Mint (or reuse) an API key, resolve a model, then fire COUNT inference
requests. After each response print that call's token usage and the
running totals.

Options:
  --count N           Number of requests (default: ${COUNT})
  --delay SECS        Sleep between requests (default: ${DELAY_SECS})
  --max-tokens N      max_tokens in payload (default: ${MAX_TOKENS})
  --endpoint NAME     chat/completions | completions | responses
  --prompt TEXT       User prompt / input (default: Hello)
  --stop-on-429       Stop the loop on first HTTP 429
  --keep-key          Keep minted API key (default: delete on exit)
  --verbose           Print response snippet on each call
  -h, --help

Env:
  API_KEY             Skip mint; use this key
  MAAS_GATEWAY_HOST   Override gateway URL
  OC_TOKEN            Override oc whoami -t (mint only)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:?}"; shift 2 ;;
    --delay) DELAY_SECS="${2:?}"; shift 2 ;;
    --max-tokens) MAX_TOKENS="${2:?}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --prompt) PROMPT="${2:?}"; shift 2 ;;
    --stop-on-429) STOP_ON_429=1; shift ;;
    --keep-key) KEEP_KEY=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown arg: $1" ;;
    *) REQUESTED_MODEL="$1"; shift ;;
  esac
done

[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || die "--count must be a positive integer"
require_cmd curl jq

HOST="$(maas_host)"
API_KEY="${API_KEY:-}"
API_KEY_ID=""
OC_TOKEN_VAL=""

cleanup() {
  if [[ "$KEEP_KEY" -eq 0 && -n "$API_KEY_ID" && -n "$OC_TOKEN_VAL" ]]; then
    curl -sSk -o /dev/null -X DELETE \
      -H "Authorization: Bearer ${OC_TOKEN_VAL}" \
      "${HOST}/maas-api/v1/api-keys/${API_KEY_ID}" 2>/dev/null || true
    info "deleted API key ${API_KEY_ID}"
  fi
}
trap cleanup EXIT

info "HOST=${HOST}"

if [[ -z "$API_KEY" ]]; then
  OC_TOKEN_VAL="$(oc_token)"
  API_KEY_NAME="burst-$(date +%s)"
  info "Minting API key name=${API_KEY_NAME}"
  KEY_RESP="$(curl -sSk --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
    -H "Authorization: Bearer ${OC_TOKEN_VAL}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"expiresIn\":\"1h\",\"name\":\"${API_KEY_NAME}\"}" \
    "${HOST}/maas-api/v1/api-keys")"
  KEY_BODY="$(echo "$KEY_RESP" | sed '$d')"
  KEY_CODE="$(echo "$KEY_RESP" | tail -n1)"
  [[ "$KEY_CODE" == "201" || "$KEY_CODE" == "200" ]] \
    || die "API key mint failed (HTTP ${KEY_CODE}): $(echo "$KEY_BODY" | head -c 300)"
  API_KEY="$(echo "$KEY_BODY" | jq -r '.key // empty')"
  API_KEY_ID="$(echo "$KEY_BODY" | jq -r '.id // empty')"
  [[ -n "$API_KEY" ]] || die "no .key in mint response"
  ok "minted key id=${API_KEY_ID}"
else
  info "Using API_KEY from env (skip mint)"
fi

info "Listing models"
MODELS_BODY="$(curl -sSk --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  "${HOST}/maas-api/v1/models")"

MODEL_NAME=""
MODEL_URL=""
if [[ -n "$REQUESTED_MODEL" ]]; then
  MODEL_NAME="$(echo "$MODELS_BODY" | jq -r --arg m "$REQUESTED_MODEL" '.data[]? | select(.id==$m) | .id' | head -1)"
  MODEL_URL="$(echo "$MODELS_BODY" | jq -r --arg m "$REQUESTED_MODEL" '.data[]? | select(.id==$m) | .url' | head -1)"
else
  MODEL_NAME="$(echo "$MODELS_BODY" | jq -r '.data[0].id // empty')"
  MODEL_URL="$(echo "$MODELS_BODY" | jq -r '.data[0].url // empty')"
fi

[[ -n "$MODEL_NAME" && "$MODEL_NAME" != "null" ]] || die "no models available"
[[ -n "$MODEL_URL" && "$MODEL_URL" != "null" ]] || die "model has no url"

if grep -q '\.svc\.cluster\.local' <<<"$MODEL_URL"; then
  MODEL_PATH="$(echo "$MODEL_URL" | sed 's|https\?://[^/]*||')"
  MODEL_URL="${HOST}${MODEL_PATH}"
  info "rewrote internal model URL → ${MODEL_URL}"
fi

CHAT_URL="${MODEL_URL%/}/v1/${ENDPOINT}"
case "$ENDPOINT" in
  chat/completions)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
      '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$t}')"
    ;;
  completions)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
      '{model:$m, prompt:$p, max_tokens:$t}')"
    ;;
  responses)
    PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
      '{model:$m, input:$p, max_tokens:$t}')"
    ;;
  *)
    die "unsupported --endpoint: $ENDPOINT"
    ;;
esac

info "Burst: count=${COUNT} delay=${DELAY_SECS}s model=${MODEL_NAME}"
info "POST ${CHAT_URL}"
echo

sum_prompt=0
sum_completion=0
sum_total=0
ok_count=0
rl_count=0
fail_count=0

printf '%-6s %-6s %8s %8s %8s | %10s %10s %10s\n' \
  '#' 'HTTP' 'prompt' 'compl' 'total' 'Σprompt' 'Σcompl' 'Σtotal'
printf '%s\n' '--------------------------------------------------------------------------------'

for i in $(seq 1 "$COUNT"); do
  RESP="$(curl -sSk --connect-timeout 10 --max-time 60 -w '\n%{http_code}' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST -d "$PAYLOAD" \
    "$CHAT_URL" 2>/dev/null || printf '\n000')"
  BODY="$(echo "$RESP" | sed '$d')"
  CODE="$(echo "$RESP" | tail -n1)"

  prompt_t=0
  compl_t=0
  total_t=0

  if [[ "$CODE" == "200" ]]; then
    ((ok_count++)) || true
    # OpenAI-style usage; fall back to 0 if missing
    read -r prompt_t compl_t total_t <<<"$(echo "$BODY" | jq -r '
      [
        (.usage.prompt_tokens // .usage.input_tokens // 0),
        (.usage.completion_tokens // .usage.output_tokens // 0),
        (.usage.total_tokens //
          ((.usage.prompt_tokens // .usage.input_tokens // 0)
           + (.usage.completion_tokens // .usage.output_tokens // 0)))
      ] | @tsv
    ' 2>/dev/null || echo '0 0 0')"
    prompt_t="${prompt_t:-0}"
    compl_t="${compl_t:-0}"
    total_t="${total_t:-0}"
    # coerce non-numeric
    [[ "$prompt_t" =~ ^[0-9]+$ ]] || prompt_t=0
    [[ "$compl_t" =~ ^[0-9]+$ ]] || compl_t=0
    [[ "$total_t" =~ ^[0-9]+$ ]] || total_t=0

    sum_prompt=$((sum_prompt + prompt_t))
    sum_completion=$((sum_completion + compl_t))
    sum_total=$((sum_total + total_t))
  elif [[ "$CODE" == "429" ]]; then
    ((rl_count++)) || true
  else
    ((fail_count++)) || true
  fi

  printf '%-6s %-6s %8s %8s %8s | %10s %10s %10s\n' \
    "$i" "$CODE" "$prompt_t" "$compl_t" "$total_t" \
    "$sum_prompt" "$sum_completion" "$sum_total"

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "$BODY" | jq -c '{usage, choices: (.choices[0].message.content // .choices[0].text // .output // null)}' 2>/dev/null \
      || echo "$BODY" | head -c 200
  fi

  if [[ "$STOP_ON_429" -eq 1 && "$CODE" == "429" ]]; then
    warn "stopping on 429 at request ${i}"
    break
  fi

  if [[ "$i" -lt "$COUNT" ]]; then
    sleep "$DELAY_SECS"
  fi
done

echo
echo "======== summary ========"
echo "requests: ok=${ok_count} 429=${rl_count} other=${fail_count}"
echo "tokens:   prompt=${sum_prompt} completion=${sum_completion} total=${sum_total}"
if [[ "$rl_count" -gt 0 ]]; then
  ok "saw rate limiting (HTTP 429)"
elif [[ "$ok_count" -eq 0 ]]; then
  die "no successful inference calls"
else
  info "no 429s — raise --count or lower subscription limits to exercise Limitador"
fi
