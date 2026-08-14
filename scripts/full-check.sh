#!/usr/bin/env bash
# Full MaaS debug check: optional echo-model infra setup + probe suite + report.
#
# Creates only MaaS-specific objects (LLMIS echo + ModelRef + AuthPolicy +
# Subscription). Does not install the platform.
#
# Usage:
#   ./scripts/full-check.sh                  # setup + run all checks
#   ./scripts/full-check.sh --skip-setup     # use existing fullcheck objects
#   ./scripts/full-check.sh --setup-only
#   ./scripts/full-check.sh --teardown
#   ./scripts/full-check.sh --request-kb 32
#
# Report printed to stdout; also written to REPORT_PATH if set
# (default ~/.tmp/maas-fullcheck-<date>.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SKIP_SETUP=0
SETUP_ONLY=0
TEARDOWN=0
REQUEST_KB="${REQUEST_KB:-32}"
MODEL_MATCH="${MODEL_MATCH:-maas-debug-echo}"
SUB="${SUBSCRIPTION:-maas-debug-echo-sub}"
REPORT_PATH="${REPORT_PATH:-$HOME/.tmp/maas-fullcheck-$(date +%Y%m%d-%H%M%S).md}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --skip-setup       Do not apply fixtures (infra already present)
  --setup-only       Apply fixtures (+wait) and exit
  --teardown         Remove full-check fixtures and exit
  --request-kb N     Large I/O prompt size (default ${REQUEST_KB})
  --model SUBSTR     Model id substring (default ${MODEL_MATCH})
  --subscription S   Subscription for mint (default ${SUB})
  --report PATH      Report output path
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-setup) SKIP_SETUP=1; shift ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    --teardown) TEARDOWN=1; shift ;;
    --request-kb) REQUEST_KB="${2:?}"; shift 2 ;;
    --model) MODEL_MATCH="${2:?}"; shift 2 ;;
    --subscription) SUB="${2:?}"; shift 2 ;;
    --report) REPORT_PATH="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

mkdir -p "$(dirname "$REPORT_PATH")"

if [[ "$TEARDOWN" -eq 1 ]]; then
  "$SCRIPT_DIR/setup-fullcheck-infra.sh" --teardown
  exit $?
fi

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  "$SCRIPT_DIR/setup-fullcheck-infra.sh" --wait || die "infra setup failed"
fi
if [[ "$SETUP_ONLY" -eq 1 ]]; then
  exit 0
fi

require_cmd curl jq python3

HOST="$(maas_host)"
CLUSTER="$(oc whoami --show-server 2>/dev/null || echo unknown)"
USER="$(oc whoami 2>/dev/null || echo unknown)"
DATE="$(date -Iseconds)"

# Results accumulated as TSV: name|status|detail
RESULTS="$(mktemp)"
trap 'cleanup_minted_api_key; rm -f "$RESULTS"' EXIT

record() {
  # record <name> <PASS|FAIL|WARN|SKIP> <detail>
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$RESULTS"
  echo "[$2] $1 — $3"
}

info "Full-check starting on ${HOST}"
info "Minting key for subscription=${SUB}"
KEEP_KEY=0
mint_api_key_with_subscription "$SUB"
trap 'cleanup_minted_api_key; rm -f "$RESULTS"' EXIT
ok "key id=${API_KEY_ID}"

resolve_model "$MODEL_MATCH"
info "Using model=${MODEL_NAME}"

# 1. Non-stream smoke (short echo)
info "Check: non-stream smoke"
SMOKE_PROMPT="fullcheck-smoke-$(date +%s)"
SMOKE_OUT="$(mktemp)"
SMOKE_CODE="$(curl -sSk --connect-timeout 10 --max-time 60 -o "$SMOKE_OUT" -w '%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg m "$MODEL_NAME" --arg p "$SMOKE_PROMPT" \
    '{model:$m,messages:[{role:"user",content:$p}],max_tokens:256}')" \
  "${MODEL_URL%/}/v1/chat/completions" || echo 000)"
if [[ "$SMOKE_CODE" == "200" ]]; then
  GOT="$(jq -r '.choices[0].message.content // empty' "$SMOKE_OUT" 2>/dev/null || true)"
  if [[ "$GOT" == "$SMOKE_PROMPT" ]]; then
    record "nonstream-smoke-echo" "PASS" "HTTP 200 echo match"
  else
    record "nonstream-smoke-echo" "FAIL" "HTTP 200 but content mismatch (need --mode echo); got_chars=${#GOT}"
  fi
else
  record "nonstream-smoke-echo" "FAIL" "HTTP ${SMOKE_CODE}"
fi
rm -f "$SMOKE_OUT"

# 2. Streaming + echo integrity
info "Check: streaming + echo integrity"
if KEEP_KEY=1 API_KEY="$API_KEY" "$SCRIPT_DIR/probe-streaming.sh" "$MODEL_NAME" \
  --expect-echo --prompt "$SMOKE_PROMPT" --max-tokens 256; then
  record "streaming-echo" "PASS" "SSE + echo integrity"
else
  record "streaming-echo" "FAIL" "probe-streaming --expect-echo failed"
fi

# 3. Large I/O both modes with echo integrity
info "Check: large I/O (request-kb=${REQUEST_KB}) stream+nonstream echo"
if KEEP_KEY=1 API_KEY="$API_KEY" "$SCRIPT_DIR/probe-large-io.sh" "$MODEL_NAME" \
  --expect-echo --request-kb "$REQUEST_KB" --response-tokens 1024 --modes both; then
  record "large-io-echo" "PASS" "request-kb=${REQUEST_KB} both modes"
else
  record "large-io-echo" "FAIL" "probe-large-io --expect-echo failed"
fi

# 4. Body routing A/B (optional soft)
info "Check: body-routing probe"
if KEEP_KEY=1 API_KEY="$API_KEY" "$SCRIPT_DIR/probe-body-routing.sh" "$MODEL_NAME" >/tmp/maas-fullcheck-body.txt 2>&1; then
  record "body-routing" "PASS" "probe completed (see /tmp/maas-fullcheck-body.txt)"
else
  # script always exits 0 currently - treat as WARN if 404 patterns
  if grep -q 'body-only HTTP 404' /tmp/maas-fullcheck-body.txt 2>/dev/null \
    && grep -q 'with-header HTTP 200' /tmp/maas-fullcheck-body.txt 2>/dev/null; then
    record "body-routing" "FAIL" "body-only 404 while header works (missing ipp-pre)"
  else
    record "body-routing" "WARN" "inconclusive; see /tmp/maas-fullcheck-body.txt"
  fi
fi

# 5. Identity spoof
info "Check: identity spoof on mint"
set +e
"$SCRIPT_DIR/probe-identity-spoof.sh" --subscription "$SUB"
SPOOF_RC=$?
set -e
case "$SPOOF_RC" in
  0) record "identity-spoof-mint" "PASS" "hardened (401/403)" ;;
  2) record "identity-spoof-mint" "FAIL" "VULNERABLE — forged X-MaaS-* accepted" ;;
  *) record "identity-spoof-mint" "WARN" "inconclusive rc=${SPOOF_RC}" ;;
esac

# 6. Quick envoy filter presence (soft)
info "Check: live envoy filters"
set +e
"$SCRIPT_DIR/print-envoy-filters.sh" >/tmp/maas-fullcheck-envoy.txt 2>&1
ENVOY_RC=$?
set -e
if [[ "$ENVOY_RC" -eq 0 ]] && grep -q 'ext_proc\|wasm\|router' /tmp/maas-fullcheck-envoy.txt; then
  record "envoy-filters" "PASS" "config_dump readable"
else
  record "envoy-filters" "WARN" "could not dump filters (rc=${ENVOY_RC})"
fi

# Build report
PASS_N=$(grep -c '|PASS|' "$RESULTS" || true)
FAIL_N=$(grep -c '|FAIL|' "$RESULTS" || true)
WARN_N=$(grep -c '|WARN|' "$RESULTS" || true)
if [[ "$FAIL_N" -gt 0 ]]; then
  VERDICT="FAIL"
elif [[ "$WARN_N" -gt 0 ]]; then
  VERDICT="PASS_WITH_WARNINGS"
else
  VERDICT="PASS"
fi

{
  echo "# MaaS full-check report"
  echo
  echo "- **When:** ${DATE}"
  echo "- **Cluster:** ${CLUSTER}"
  echo "- **User:** ${USER}"
  echo "- **Gateway:** ${HOST}"
  echo "- **Model:** ${MODEL_NAME}"
  echo "- **Subscription:** ${SUB}"
  echo "- **Verdict:** ${VERDICT}"
  echo "- **Totals:** pass=${PASS_N} fail=${FAIL_N} warn=${WARN_N}"
  echo
  echo "## Results"
  echo
  echo "| Check | Status | Detail |"
  echo "|-------|--------|--------|"
  while IFS='|' read -r name status detail; do
    echo "| ${name} | ${status} | ${detail} |"
  done < "$RESULTS"
  echo
  echo "## Notes"
  echo
  echo "- Echo integrity requires LLMIS \`--mode echo\` (fixtures/fullcheck-echo)."
  echo "- Identity spoof FAIL means forged \`X-MaaS-Username\`/\`Group\` were accepted on mint."
  echo "- Teardown: \`./scripts/full-check.sh --teardown\`"
  echo
} | tee "$REPORT_PATH"

info "Report written to ${REPORT_PATH}"
[[ "$FAIL_N" -eq 0 ]]
