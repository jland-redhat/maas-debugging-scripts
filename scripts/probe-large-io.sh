#!/usr/bin/env bash
# Validate large request and/or large response for BOTH non-streaming and streaming.
#
# Useful for wasm/ext_proc body-chunk bugs and gateway buffering issues.
#
# Usage:
#   ./scripts/probe-large-io.sh
#   ./scripts/probe-large-io.sh sim-chat --request-kb 64 --response-tokens 512
#   ./scripts/probe-large-io.sh my-model --modes both --request-kb 256
#
# Simulator note (llm-d-inference-sim):
#   Large responses: script sends ignore_eos=true + max_tokens (random mode).
#   If that is not enough, agents MUST ask before patching the LLMIS
#   (e.g. --mode echo so a large prompt is mirrored as a large response).
#
# Env: MAAS_GATEWAY_HOST, API_KEY, KEEP_KEY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

REQUESTED_MODEL=""
REQUEST_KB="${REQUEST_KB:-64}"
RESPONSE_TOKENS="${RESPONSE_TOKENS:-256}"
MODES="both"
KEEP_KEY="${KEEP_KEY:-0}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [MODEL_NAME]

Run large I/O probes against /v1/chat/completions.

Options:
  --request-kb N         Approx prompt size in KiB (default ${REQUEST_KB})
  --response-tokens N    max_tokens (+ ignore_eos for simulators) (default ${RESPONSE_TOKENS})
  --modes MODE           nonstream | stream | both (default both)
  --timeout SECS         curl max-time (default ${TIMEOUT_SECS})
  --keep-key             Keep minted API key
  --verbose              Extra details
  -h, --help

Simulator tip:
  Detected llm-d / sample simulator models print a notice. For guaranteed
  large responses, prefer ignore_eos (sent automatically) or ask an operator
  to set the simulator --mode echo and use a large --request-kb.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --request-kb) REQUEST_KB="${2:?}"; shift 2 ;;
    --response-tokens) RESPONSE_TOKENS="${2:?}"; shift 2 ;;
    --modes) MODES="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT_SECS="${2:?}"; shift 2 ;;
    --keep-key) KEEP_KEY=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown arg: $1" ;;
    *) REQUESTED_MODEL="$1"; shift ;;
  esac
done

case "$MODES" in
  nonstream|stream|both) ;;
  *) die "--modes must be nonstream|stream|both" ;;
esac

require_cmd curl jq python3
ensure_api_key
resolve_model "$REQUESTED_MODEL"

CHAT_URL="${MODEL_URL%/}/v1/chat/completions"
PROMPT_FILE="$(mktemp)"
trap 'cleanup_minted_api_key; rm -f "$PROMPT_FILE"' EXIT

python3 - "$PROMPT_FILE" "$REQUEST_KB" <<'PY'
import sys
path, kb = sys.argv[1], int(sys.argv[2])
unit = ("LARGE-PAYLOAD-PROBE " * 8) + ("abcdefghijklmnopqrstuvwxyz0123456789\n")
need = kb * 1024
buf, n = [], 0
while n < need:
    buf.append(unit)
    n += len(unit)
open(path, "w").write("".join(buf)[:need])
print(f"prompt_bytes={need}")
PY

PROMPT="$(cat "$PROMPT_FILE")"
PROMPT_BYTES="${#PROMPT}"

SIM=0
if is_simulator_model "$MODEL_NAME"; then
  SIM=1
  echo
  warn "Detected likely llm-d-inference-sim / sample simulator model: ${MODEL_NAME}"
  echo "  Large response strategy: send ignore_eos=true + max_tokens=${RESPONSE_TOKENS}."
  echo "  If completion stays short, ask before patching the LLMIS (e.g. --mode echo)"
  echo "  so a large prompt is mirrored as a large response."
  echo
fi

run_one() {
  local mode="$1"
  local stream_json=false
  local curl_extra=()
  local out hdr code payload

  out="$(mktemp)"
  hdr="$(mktemp)"

  if [[ "$mode" == "stream" ]]; then
    stream_json=true
    curl_extra=(--no-buffer)
  fi

  payload="$(jq -nc \
    --arg m "$MODEL_NAME" \
    --arg p "$PROMPT" \
    --argjson t "$RESPONSE_TOKENS" \
    --argjson stream "$stream_json" \
    --argjson sim "$SIM" '
      {
        model: $m,
        messages: [{role:"user", content:$p}],
        max_tokens: $t,
        stream: $stream
      }
      + (if $stream then {stream_options:{include_usage:true}} else {} end)
      + (if $sim == 1 then {ignore_eos:true} else {} end)
    ')"

  info "[${mode}] POST ${CHAT_URL} (prompt=${PROMPT_BYTES}B max_tokens=${RESPONSE_TOKENS})"
  code="$(curl -sSk --connect-timeout 15 --max-time "$TIMEOUT_SECS" \
    "${curl_extra[@]}" \
    -D "$hdr" -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST -d "$payload" \
    "$CHAT_URL" || echo 000)"

  echo "  HTTP ${code}  response_bytes=$(wc -c < "$out" | tr -d ' ')"

  if [[ "$code" != "200" ]]; then
    echo "  body preview: $(head -c 300 "$out" | tr '\n' ' ')"
    rm -f "$out" "$hdr"
    return 1
  fi

  if [[ "$mode" == "nonstream" ]]; then
    python3 - "$out" "$RESPONSE_TOKENS" "$VERBOSE" <<'PY' || { rm -f "$out" "$hdr"; return 1; }
import json, sys
path, want, verbose = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
o = json.load(open(path))
content = ""
for c in o.get("choices") or []:
    msg = c.get("message") or {}
    if msg.get("content"):
        content += msg["content"]
    if c.get("text"):
        content += c["text"]
usage = o.get("usage") or {}
compl = usage.get("completion_tokens") or usage.get("output_tokens") or 0
finish = ((o.get("choices") or [{}])[0].get("finish_reason"))
print(f"  content_chars={len(content)} completion_tokens={compl} finish={finish}")
if verbose:
    print(f"  usage={usage}")
if len(content) < 8 and int(compl or 0) < 1:
    print("  FAIL: empty completion", file=sys.stderr)
    sys.exit(1)
if want >= 64 and len(content) < 32 and int(compl or 0) < 16:
    print("  FAIL: response much smaller than requested (simulator may need --mode echo)", file=sys.stderr)
    sys.exit(1)
print("  OK nonstream large I/O")
PY
  else
    python3 - "$out" "$RESPONSE_TOKENS" "$VERBOSE" <<'PY' || { rm -f "$out" "$hdr"; return 1; }
import json, sys
path, want, verbose = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
raw = open(path, "rb").read().decode("utf-8", "replace")
data = [ln[5:].strip() for ln in raw.splitlines() if ln.startswith("data:")]
chunks = [d for d in data if d and d != "[DONE]"]
done = any(d == "[DONE]" for d in data)
parts, usage, finish = [], None, None
for d in chunks:
    try:
        o = json.loads(d)
    except Exception:
        continue
    if o.get("usage"):
        usage = o["usage"]
    for c in o.get("choices") or []:
        if c.get("finish_reason"):
            finish = c["finish_reason"]
        delta = c.get("delta") or {}
        if delta.get("content"):
            parts.append(delta["content"])
text = "".join(parts)
compl = (usage or {}).get("completion_tokens") or (usage or {}).get("output_tokens") or 0
print(f"  sse_json_chunks={len(chunks)} content_chars={len(text)} completion_tokens={compl} finish={finish} done={done}")
if verbose and usage:
    print(f"  usage={usage}")
if len(chunks) < 2:
    print("  FAIL: too few SSE chunks", file=sys.stderr)
    sys.exit(1)
if not done and not finish:
    print("  FAIL: missing stream termination", file=sys.stderr)
    sys.exit(1)
if want >= 64 and len(text) < 32 and int(compl or 0) < 16:
    print("  FAIL: streamed content much smaller than requested (simulator may need --mode echo)", file=sys.stderr)
    sys.exit(1)
print("  OK stream large I/O")
PY
  fi

  rm -f "$out" "$hdr"
  return 0
}

FAIL=0
if [[ "$MODES" == "nonstream" || "$MODES" == "both" ]]; then
  run_one nonstream || FAIL=1
fi
if [[ "$MODES" == "stream" || "$MODES" == "both" ]]; then
  run_one stream || FAIL=1
fi

echo
if [[ "$FAIL" -ne 0 ]]; then
  die "large I/O probe failed (see above). If simulator: ask to switch LLMIS --mode echo for large mirrored responses."
fi
ok "large I/O probe passed for model=${MODEL_NAME} modes=${MODES}"
