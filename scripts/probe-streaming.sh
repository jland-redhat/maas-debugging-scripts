#!/usr/bin/env bash
# Validate SSE streaming chat/completions through the MaaS gateway.
#
# Checks: HTTP 200, text/event-stream (or SSE-shaped body), multiple data:
# chunks, a [DONE] (or finish_reason), and optional content accumulation.
#
# Usage:
#   ./scripts/probe-streaming.sh
#   ./scripts/probe-streaming.sh sim-chat --max-tokens 80
#   API_KEY=sk-... ./scripts/probe-streaming.sh my-model --verbose
#
# Env: MAAS_GATEWAY_HOST, API_KEY, MAX_TOKENS, KEEP_KEY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

REQUESTED_MODEL=""
MAX_TOKENS="${MAX_TOKENS:-64}"
PROMPT="${PROMPT:-Count from 1 to 20 slowly.}"
VERBOSE=0
KEEP_KEY="${KEEP_KEY:-0}"
MIN_CHUNKS="${MIN_CHUNKS:-2}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [MODEL_NAME]

POST /v1/chat/completions with stream=true and validate SSE framing.

Options:
  --max-tokens N   Default ${MAX_TOKENS}
  --prompt TEXT    User message
  --min-chunks N   Minimum data: events expected (default ${MIN_CHUNKS})
  --keep-key       Keep minted API key
  --verbose        Print first/last SSE lines
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-tokens) MAX_TOKENS="${2:?}"; shift 2 ;;
    --prompt) PROMPT="${2:?}"; shift 2 ;;
    --min-chunks) MIN_CHUNKS="${2:?}"; shift 2 ;;
    --keep-key) KEEP_KEY=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown arg: $1" ;;
    *) REQUESTED_MODEL="$1"; shift ;;
  esac
done

require_cmd curl jq python3
ensure_api_key
resolve_model "$REQUESTED_MODEL"

CHAT_URL="${MODEL_URL%/}/v1/chat/completions"
PAYLOAD="$(jq -nc --arg m "$MODEL_NAME" --arg p "$PROMPT" --argjson t "$MAX_TOKENS" \
  '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$t, stream:true, stream_options:{include_usage:true}}')"

info "Streaming POST ${CHAT_URL}"
info "model=${MODEL_NAME} max_tokens=${MAX_TOKENS}"

HDR="$(mktemp)"
BODY="$(mktemp)"
trap 'cleanup_minted_api_key; rm -f "$HDR" "$BODY"' EXIT

HTTP_CODE="$(curl -sSk --no-buffer --connect-timeout 10 --max-time 180 \
  -D "$HDR" -o "$BODY" -w '%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -X POST -d "$PAYLOAD" \
  "$CHAT_URL" || echo 000)"

CT="$(grep -i '^content-type:' "$HDR" | tr -d '\r' | awk '{print tolower($0)}' || true)"
echo "HTTP ${HTTP_CODE}"
echo "Content-Type: ${CT:-"(none)"}"

python3 - "$BODY" "$MIN_CHUNKS" "$VERBOSE" <<'PY'
import json, sys, re
path, min_chunks, verbose = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
raw = open(path, "rb").read().decode("utf-8", "replace")
lines = raw.splitlines()
data_lines = [ln[5:].strip() for ln in lines if ln.startswith("data:")]
chunks = [d for d in data_lines if d and d != "[DONE]"]
done = any(d == "[DONE]" for d in data_lines)
content_parts = []
finish = None
usage = None
parse_err = 0
for d in chunks:
    try:
        o = json.loads(d)
    except json.JSONDecodeError:
        parse_err += 1
        continue
    if "usage" in o and o["usage"]:
        usage = o["usage"]
    for c in o.get("choices") or []:
        fr = c.get("finish_reason")
        if fr:
            finish = fr
        delta = c.get("delta") or {}
        if "content" in delta and delta["content"]:
            content_parts.append(delta["content"])
        # some backends put content in message for non-delta frames
        msg = c.get("message") or {}
        if msg.get("content"):
            content_parts.append(msg["content"])

text = "".join(content_parts)
print(f"data_events={len(data_lines)} json_chunks={len(chunks)} parse_errors={parse_err}")
print(f"done_marker={done} finish_reason={finish}")
print(f"content_chars={len(text)} content_preview={text[:120]!r}")
if usage:
    print(f"usage={json.dumps(usage)}")
if verbose:
    print("--- first 8 SSE lines ---")
    for ln in lines[:8]:
        print(ln[:200])
    print("--- last 8 SSE lines ---")
    for ln in lines[-8:]:
        print(ln[:200])

ok = True
reasons = []
if len(chunks) < min_chunks:
    ok = False
    reasons.append(f"need >= {min_chunks} JSON data chunks, got {len(chunks)}")
if not done and not finish:
    ok = False
    reasons.append("missing [DONE] and finish_reason")
if parse_err and len(chunks) == 0:
    ok = False
    reasons.append("no parseable SSE JSON")
if not ok:
    print("FAIL:", "; ".join(reasons), file=sys.stderr)
    sys.exit(1)
print("OK: streaming SSE looks healthy")
PY
STREAM_RC=$?

[[ "$HTTP_CODE" == "200" ]] || die "streaming HTTP ${HTTP_CODE} (expected 200)"
# Soft-warn on content-type (some gateways omit or use application/json)
if [[ -n "$CT" ]] && ! grep -qiE 'text/event-stream|application/json|octet-stream' <<<"$CT"; then
  warn "unexpected Content-Type: $CT"
fi
[[ "$STREAM_RC" -eq 0 ]] || exit 1
ok "streaming probe passed for model=${MODEL_NAME}"
