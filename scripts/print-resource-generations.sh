#!/usr/bin/env bash
# Print Kubernetes metadata.generation for Gateways and EnvoyFilters.
#
# "Generations" here means API object churn (RHOAIENG-81865), NOT LLM tokens.
# Quiet objects stay near generation 1. Thousands in a short window ⇒ reconcile
# loop / EnvoyFilter leakage → gateway OOM risk.
#
# Usage:
#   ./scripts/print-resource-generations.sh
#   ./scripts/print-resource-generations.sh --watch 5
#   EF_NS=openshift-ingress ./scripts/print-resource-generations.sh
#   GATEWAY=kuadrant-maas-default-gateway GATEWAY_NS=openshift-ingress \
#     ./scripts/print-resource-generations.sh --detail
#
# Source: Slack thread / RHOAIENG-81865 triage (2026-08-07)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

WATCH_SECS=0
DETAIL=0
WARN_THRESHOLD="${WARN_THRESHOLD:-50}"

usage() {
  cat <<EOF
Usage: $0 [--watch SECONDS] [--detail] [-h]

Print metadata.generation for Gateways (cluster-wide) and EnvoyFilters
in EF_NS (default: openshift-ingress).

  --watch N   Re-print every N seconds (Ctrl-C to stop)
  --detail    Also dump generation/resourceVersion for GATEWAY/GATEWAY_NS
  -h          Help

Env:
  EF_NS            EnvoyFilter namespace (default: openshift-ingress)
  WARN_THRESHOLD   Flag generation >= this (default: 50)
  GATEWAY          With --detail: gateway name to inspect
  GATEWAY_NS       With --detail: gateway namespace
  KUBECONFIG / KUBECTL as usual
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH_SECS="${2:?}"; shift 2 ;;
    --detail) DETAIL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

print_once() {
  local ts
  ts="$(date -Iseconds)"
  echo
  echo "======== ${ts} ========"

  info "Gateways (all namespaces)"
  "$KUBECTL" get gateway -A -o custom-columns=\
NAME:.metadata.name,NS:.metadata.namespace,GENERATION:.metadata.generation,AGE:.metadata.creationTimestamp

  echo
  info "EnvoyFilters in ${EF_NS}"
  if "$KUBECTL" get ns "$EF_NS" >/dev/null 2>&1; then
    "$KUBECTL" get envoyfilter -n "$EF_NS" -o custom-columns=\
NAME:.metadata.name,GENERATION:.metadata.generation,AGE:.metadata.creationTimestamp,PRIORITY:.spec.priority
  else
    warn "namespace ${EF_NS} not found"
  fi

  # Highlight high-generation objects
  echo
  info "High generation (>= ${WARN_THRESHOLD})"
  "$KUBECTL" get gateway -A -o json 2>/dev/null | python3 -c '
import json,sys
thr=int(sys.argv[1])
items=json.load(sys.stdin).get("items",[])
hits=[]
for i in items:
  g=i.get("metadata",{}).get("generation",0) or 0
  if g>=thr:
    m=i["metadata"]
    hits.append((g, m.get("namespace",""), m.get("name",""), "Gateway"))
for g,ns,name,kind in sorted(hits, reverse=True):
  print(f"  {kind} {ns}/{name}: generation={g}")
if not hits:
  print("  (none among Gateways)")
' "$WARN_THRESHOLD" || true

  "$KUBECTL" get envoyfilter -n "$EF_NS" -o json 2>/dev/null | python3 -c '
import json,sys
thr=int(sys.argv[1])
items=json.load(sys.stdin).get("items",[])
hits=[]
for i in items:
  g=i.get("metadata",{}).get("generation",0) or 0
  if g>=thr:
    m=i["metadata"]
    hits.append((g, m.get("name","")))
for g,name in sorted(hits, reverse=True):
  print(f"  EnvoyFilter {name}: generation={g}")
if not hits:
  print("  (none among EnvoyFilters)")
' "$WARN_THRESHOLD" || true

  if [[ "$DETAIL" -eq 1 ]]; then
    local gname="${GATEWAY:-}"
    local gns="${GATEWAY_NS:-$GW_NS}"
    if [[ -n "$gname" ]]; then
      echo
      info "Detail: Gateway ${gns}/${gname}"
      "$KUBECTL" get gateway "$gname" -n "$gns" -o yaml 2>/dev/null \
        | grep -E '^\s*(generation|resourceVersion):' || warn "not found"
    fi
  fi

  echo
  echo "Hint: quiet ≈ generation 1; rapid climb ⇒ filter leakage / reconcile loop (RHOAIENG-81865)."
}

if [[ "$WATCH_SECS" -gt 0 ]]; then
  while true; do
    print_once
    sleep "$WATCH_SECS"
  done
else
  print_once
fi
