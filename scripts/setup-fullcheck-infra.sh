#!/usr/bin/env bash
# Apply / wait / teardown full-check echo fixtures (MaaS CRs + LLMIS only).
#
# Does NOT install MaaS/Kuadrant/gateway — only validates they look present,
# then creates subscription + auth policy + echo simulator model.
#
# Usage:
#   ./scripts/setup-fullcheck-infra.sh
#   ./scripts/setup-fullcheck-infra.sh --wait
#   ./scripts/setup-fullcheck-infra.sh --teardown
#   ./scripts/setup-fullcheck-infra.sh --status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

FIXTURES="${SCRIPT_DIR}/../fixtures/fullcheck-echo"
MODEL_NS="${MODEL_NS:-llm}"
MAAS_NS="${MAAS_NS:-models-as-a-service}"
LLMIS_NAME="${LLMIS_NAME:-maas-debug-echo}"
WAIT=0
TEARDOWN=0
STATUS=0
TIMEOUT="${TIMEOUT:-300}"

usage() {
  cat <<EOF
Usage: $0 [--wait] [--teardown] [--status] [-h]

  (default)   kubectl apply -k fixtures/fullcheck-echo
  --wait      After apply, wait until MaaSModelRef/LLMIS look Ready
  --teardown  Delete objects labeled maas.opendatahub.io/fullcheck=echo
  --status    Print status of full-check objects

Env: MODEL_NS (llm), MAAS_NS (models-as-a-service), TIMEOUT (300)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --teardown) TEARDOWN=1; shift ;;
    --status) STATUS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

preflight_maas() {
  info "Preflight: MaaS platform present?"
  local okc=0
  if "$KUBECTL" get gateway maas-default-gateway -n openshift-ingress >/dev/null 2>&1; then
    ok "Gateway maas-default-gateway"
    okc=$((okc + 1))
  else
    warn "Gateway maas-default-gateway missing in openshift-ingress"
  fi
  if "$KUBECTL" get deploy -A 2>/dev/null | grep -q 'maas-api'; then
    ok "maas-api deployment found"
    okc=$((okc + 1))
  else
    warn "maas-api deployment not found"
  fi
  if "$KUBECTL" get deploy -A 2>/dev/null | grep -q 'maas-controller'; then
    ok "maas-controller deployment found"
    okc=$((okc + 1))
  else
    warn "maas-controller deployment not found"
  fi
  if "$KUBECTL" get crd maasmodelrefs.maas.opendatahub.io >/dev/null 2>&1 \
    || "$KUBECTL" get crd maasmodelrefs.maas.io >/dev/null 2>&1; then
    ok "MaaSModelRef CRD present"
    okc=$((okc + 1))
  else
    die "MaaS CRDs missing — install MaaS before running full-check infra setup"
  fi
  [[ "$okc" -ge 2 ]] || die "MaaS does not look installed enough to continue (gateway/api/controller)"
}

print_status() {
  info "Full-check objects"
  "$KUBECTL" get ns llm models-as-a-service 2>/dev/null || true
  "$KUBECTL" get llminferenceservice "$LLMIS_NAME" -n "$MODEL_NS" -o wide 2>/dev/null || warn "LLMIS missing"
  "$KUBECTL" get maasmodelref "$LLMIS_NAME" -n "$MODEL_NS" -o wide 2>/dev/null || warn "MaaSModelRef missing"
  "$KUBECTL" get maasauthpolicy maas-debug-echo-access -n "$MAAS_NS" 2>/dev/null || warn "MaaSAuthPolicy missing"
  "$KUBECTL" get maassubscription maas-debug-echo-sub -n "$MAAS_NS" 2>/dev/null || warn "MaaSSubscription missing"
  "$KUBECTL" get httproute -n "$MODEL_NS" 2>/dev/null | grep -i echo || true
  "$KUBECTL" get maasmodelref "$LLMIS_NAME" -n "$MODEL_NS" -o jsonpath='phase={.status.phase} endpoint={.status.endpoint}{"\n"}' 2>/dev/null || true
}

if [[ "$STATUS" -eq 1 ]]; then
  print_status
  exit 0
fi

if [[ "$TEARDOWN" -eq 1 ]]; then
  info "Tearing down full-check fixtures"
  # Delete CRs first, then leave namespaces (shared llm / models-as-a-service often already existed)
  "$KUBECTL" delete maassubscription maas-debug-echo-sub -n "$MAAS_NS" --ignore-not-found
  "$KUBECTL" delete maasauthpolicy maas-debug-echo-access -n "$MAAS_NS" --ignore-not-found
  "$KUBECTL" delete maasmodelref "$LLMIS_NAME" -n "$MODEL_NS" --ignore-not-found
  "$KUBECTL" delete llminferenceservice "$LLMIS_NAME" -n "$MODEL_NS" --ignore-not-found
  ok "teardown requested (namespaces llm / models-as-a-service left intact)"
  exit 0
fi

preflight_maas
require_cmd "$KUBECTL"

info "Applying ${FIXTURES}"
if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$FIXTURES" | "$KUBECTL" apply --server-side=true --force-conflicts -f -
else
  "$KUBECTL" apply --server-side=true --force-conflicts -k "$FIXTURES"
fi

if [[ "$WAIT" -eq 1 ]]; then
  info "Waiting up to ${TIMEOUT}s for model readiness"
  # LLMIS Ready condition name varies; also poll MaaSModelRef phase
  local_deadline=$((SECONDS + TIMEOUT))
  while (( SECONDS < local_deadline )); do
    phase="$("$KUBECTL" get maasmodelref "$LLMIS_NAME" -n "$MODEL_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    endpoint="$("$KUBECTL" get maasmodelref "$LLMIS_NAME" -n "$MODEL_NS" -o jsonpath='{.status.endpoint}' 2>/dev/null || true)"
    echo "  MaaSModelRef phase=${phase:-?} endpoint=${endpoint:-?}"
    if [[ "$phase" == "Ready" || "$phase" == "Available" || -n "$endpoint" ]]; then
      # Prefer Ready; accept Available/endpoint as good enough
      if [[ "$phase" == "Ready" || "$phase" == "Available" ]]; then
        ok "MaaSModelRef ready (phase=${phase})"
        break
      fi
    fi
    # Fallback: LLMIS pods running
    ready="$("$KUBECTL" get pods -n "$MODEL_NS" -l 'app.kubernetes.io/name=maas-debug-echo' --no-headers 2>/dev/null | grep -c Running || true)"
    pods="$("$KUBECTL" get pods -n "$MODEL_NS" 2>/dev/null | grep -c maas-debug-echo || true)"
    if [[ "${pods:-0}" -gt 0 ]]; then
      "$KUBECTL" get pods -n "$MODEL_NS" 2>/dev/null | grep maas-debug-echo || true
    fi
    sleep 5
  done
  print_status
fi

ok "full-check infra applied"
echo "Subscription: maas-debug-echo-sub"
echo "ModelRef:     ${MODEL_NS}/maas-debug-echo (echo mode)"
echo "Next:         ./scripts/full-check.sh --skip-setup"
