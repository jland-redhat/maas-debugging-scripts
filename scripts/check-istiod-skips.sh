#!/usr/bin/env bash
# Grep istiod logs for EnvoyFilter apply/skip reasons.
#
# Usage:
#   ./scripts/check-istiod-skips.sh
#   SINCE=4h ./scripts/check-istiod-skips.sh
#
# Source: personal-knowledge-base/maas/gateway-debugging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SINCE="${SINCE:-2h}"
ISTIOD_DEPLOY="${ISTIOD_DEPLOY:-istiod-openshift-gateway}"

info "Logs from ${GW_NS}/deploy/${ISTIOD_DEPLOY} since=${SINCE}"
"$KUBECTL" logs -n "$GW_NS" "deploy/${ISTIOD_DEPLOY}" --since="$SINCE" 2>&1 \
  | grep -iE 'envoyfilter|payload-processing|could not find|applied|skip|ignore|invalid' \
  | sort | uniq -c | sort -rn | head -40 \
  || warn "no matching lines (deploy name may differ — try: oc get deploy -n ${GW_NS} | grep istiod)"
