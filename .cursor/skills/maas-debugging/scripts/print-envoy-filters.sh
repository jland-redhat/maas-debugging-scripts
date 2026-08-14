#!/usr/bin/env bash
# Print the live Envoy HTTP filter chain on the MaaS gateway pod.
#
# Prefer this over trusting EnvoyFilter CRs — an EF can exist while inserts never apply.
#
# Usage:
#   ./scripts/print-envoy-filters.sh
#   ./scripts/print-envoy-filters.sh --stats
#   ./scripts/print-envoy-filters.sh --dump /tmp/gw-config.json
#   GW_NAME=partner ./scripts/print-envoy-filters.sh
#
# Sources: personal-knowledge-base/maas/gateway-debugging,
#          maas-billing/scripts/check-payload-ext-proc-filters.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SHOW_STATS=0
DUMP_PATH=""

usage() {
  cat <<EOF
Usage: $0 [--stats] [--dump PATH] [-h]

Port-forward Envoy admin (:15000) on the gateway pod and print http_filters
in listener order.

  --stats       Also print ext_proc / wasm / ipp stats
  --dump PATH   Save full config_dump JSON to PATH
  -h            Help

Env:
  GW_NS / GW_NAME   Gateway (default: openshift-ingress / maas-default-gateway)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stats) SHOW_STATS=1; shift ;;
    --dump) DUMP_PATH="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

require_cmd curl python3

POD="$(gateway_pod "$GW_NS" "$GW_NAME")"
info "Gateway pod: ${GW_NS}/${POD}"

run_admin() {
  local port="$1"

  if [[ -n "$DUMP_PATH" ]]; then
    curl -fsS "http://127.0.0.1:${port}/config_dump" -o "$DUMP_PATH"
    ok "wrote full config_dump → ${DUMP_PATH}"
  fi

  info "Live http_filters (all chains found)"
  curl -fsS "http://127.0.0.1:${port}/config_dump?resource=dynamic_listeners" | python3 -c '
import sys, json
d = json.load(sys.stdin)
chains = []

def walk(o):
    if isinstance(o, dict):
        if "http_filters" in o:
            names = [f.get("name", "") for f in o["http_filters"]]
            chains.append(names)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

walk(d)
if not chains:
    print("ERROR: no http_filters in config_dump", file=sys.stderr)
    sys.exit(1)

def score(names):
    s = 0
    joined = " ".join(names)
    if "envoy.filters.http.wasm" in joined or "wasmplugin" in joined:
        s += 10
    if "envoy.filters.http.router" in names:
        s += 1
    if any("ext_proc" in n for n in names):
        s += 5
    return s

for i, names in enumerate(sorted(chains, key=score, reverse=True)):
    print(f"\n--- chain #{i+1} (score={score(names)}) ---")
    for n in names:
        print(f"  - {n}")

# Quick health hints on best-scoring chain
names = sorted(chains, key=score, reverse=True)[0]
joined = " ".join(names)
print("\nHints:")
if "ext_proc" not in joined:
    print("  - no ext_proc in top chain → body routing / IPP may be missing (404 NR)")
if "wasm" not in joined and "ext_authz" not in joined:
    print("  - no wasm/ext_authz → Kuadrant auth may be missing")
if "envoy.filters.http.router" not in names:
    print("  - no router filter (unexpected)")
pre = next((i for i,n in enumerate(names) if n.endswith(".ipp-pre") or "ipp-pre" in n), -1)
auth = next((i for i,n in enumerate(names) if "wasm" in n or "ext_authz" in n), -1)
ipp = next((i for i,n in enumerate(names) if n.endswith(".ipp") or n.endswith("ext_proc.ipp")), -1)
router = next((i for i,n in enumerate(names) if n.endswith(".router")), -1)
if pre >= 0 and auth >= 0 and ipp >= 0 and router >= 0:
    if pre < auth < ipp < router:
        print("  - order looks healthy: ipp-pre → auth → ipp → router")
    else:
        print(f"  - order unexpected: pre={pre} auth={auth} ipp={ipp} router={router}")
'

  curl -fsS "http://127.0.0.1:${port}/server_info" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("\nEnvoy version:", d.get("version"))
' || true

  if [[ "$SHOW_STATS" -eq 1 ]]; then
    echo
    info "ext_proc / wasm / ipp stats (first 50)"
    curl -fsS "http://127.0.0.1:${port}/stats" \
      | grep -iE 'ext_proc|wasm|ipp-pre|ipp[^a-z]' | head -50 || true
  fi
}

with_envoy_admin "$POD" "$GW_NS" run_admin
