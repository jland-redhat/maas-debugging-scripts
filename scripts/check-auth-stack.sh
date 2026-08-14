#!/usr/bin/env bash
# Inventory AuthPolicy / Authorino / NetworkPolicy pieces that gate MaaS API keys.
#
# Usage:
#   ./scripts/check-auth-stack.sh
#   ./scripts/check-auth-stack.sh --logs
#
# Sources: Praxis key-mint failures, AuthPolicy triage transcripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SHOW_LOGS=0

usage() {
  cat <<EOF
Usage: $0 [--logs] [-h]

Show AuthPolicy / AuthConfig / NetworkPolicy inventory for MaaS auth debugging.

  --logs   Tail recent Authorino + maas-api logs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs) SHOW_LOGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

MAAS_API_NS="$(detect_maas_api_ns)"
info "MAAS_API_NS=${MAAS_API_NS}"
info "GW_NS=${GW_NS}"

echo
info "AuthPolicy (all namespaces)"
"$KUBECTL" get authpolicy -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,KIND:.spec.targetRef.kind,TARGET:.spec.targetRef.name 2>/dev/null \
  || warn "AuthPolicy CRD missing?"

echo
info "Interesting AuthPolicies (maas-gateway-auth / gateway-default-auth / maas-api)"
"$KUBECTL" get authpolicy -A 2>/dev/null | grep -iE 'maas-gateway-auth|gateway-default-auth|maas-api' || echo "(none matched)"

if "$KUBECTL" get crd maasauthpolicies.maas.opendatahub.io >/dev/null 2>&1 \
  || "$KUBECTL" get maasauthpolicy -A >/dev/null 2>&1; then
  echo
  info "MaaSAuthPolicy"
  "$KUBECTL" get maasauthpolicy -A 2>/dev/null || true
fi

echo
info "Authorino AuthConfigs (kuadrant-managed)"
"$KUBECTL" get authconfig -n kuadrant-system -l kuadrant.io/managed=true \
  -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hosts,IDENTITY:.status.summary.numIdentitySources,AUTHZ:.status.summary.numAuthorizationPolicies' \
  2>/dev/null || warn "no AuthConfigs / kuadrant-system missing"

echo
info "NetworkPolicies touching authorino / maas-api"
"$KUBECTL" get networkpolicy -A 2>/dev/null | grep -iE 'maas|authorino|kuadrant' || echo "(none matched)"
"$KUBECTL" get networkpolicy maas-authorino-allow -n "$MAAS_API_NS" -o yaml 2>/dev/null \
  | head -40 || warn "maas-authorino-allow not in ${MAAS_API_NS}"

echo
info "maas-api pods"
"$KUBECTL" get pods -n "$MAAS_API_NS" -l app.kubernetes.io/name=maas-api 2>/dev/null \
  || "$KUBECTL" get pods -n "$MAAS_API_NS" 2>/dev/null | grep -i maas-api || true

if [[ "$SHOW_LOGS" -eq 1 ]]; then
  echo
  info "Authorino logs (last 40 matching lines)"
  "$KUBECTL" logs -n kuadrant-system -l app.kubernetes.io/name=authorino --tail=80 2>&1 \
    | grep -iE '401|denied|unauth|token|error|maas-api|AUTH_FAILURE' | tail -40 || true

  echo
  info "maas-api logs (tail 40)"
  "$KUBECTL" logs -n "$MAAS_API_NS" deploy/maas-api --tail=40 2>&1 || true
fi

echo
echo "Hints:"
echo "  - Key mint AUTH_FAILURE / missing X-MaaS-Username → AuthPolicy / ExtProc identity inject"
echo "  - Auth hang ~10s → Authorino→maas-api NetworkPolicy / connectivity"
echo "  - Direct bypass: oc port-forward svc/maas-api + forge X-MaaS-Username / X-MaaS-Group"
