#!/usr/bin/env bash
# Inventory intended EnvoyFilter / WasmPlugin config (not live chain).
#
# Usage:
#   ./scripts/inventory-envoyfilters.sh
#
# Source: personal-knowledge-base/maas/gateway-debugging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

info "EnvoyFilters in ${EF_NS}"
"$KUBECTL" get envoyfilter -n "$EF_NS" -o custom-columns=\
NAME:.metadata.name,PRIORITY:.spec.priority,GENERATION:.metadata.generation,AGE:.metadata.creationTimestamp

echo
info "Who targets what?"
"$KUBECTL" get envoyfilter -n "$EF_NS" -o json | python3 -c '
import json, sys
for i in json.load(sys.stdin)["items"]:
    s = i.get("spec") or {}
    m = i["metadata"]
    print(m["name"],
          "priority=", s.get("priority"),
          "targetRefs=", s.get("targetRefs"),
          "workloadSelector=", s.get("workloadSelector"))
'

echo
info "WasmPlugins (all namespaces)"
"$KUBECTL" get wasmplugin -A 2>/dev/null || warn "WasmPlugin CRD missing?"

echo
info "Gateway ${GW_NS}/${GW_NAME} (brief)"
"$KUBECTL" get gateway "$GW_NAME" -n "$GW_NS" -o yaml 2>/dev/null | head -80 || warn "gateway not found"

echo
info "payload-processing insert anchors (if present)"
"$KUBECTL" get envoyfilter payload-processing -n "$EF_NS" -o yaml 2>/dev/null \
  | grep -nE 'applyTo:|INSERT_|name: envoy\.filters|subFilter|targetRefs|priority|workloadSelector' \
  | head -60 || warn "payload-processing EnvoyFilter not found"

echo
echo "Next: confirm LIVE filters with ./scripts/print-envoy-filters.sh"
echo "An EnvoyFilter existing is NOT proof the HTTP filter is loaded."
