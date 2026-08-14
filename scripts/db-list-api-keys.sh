#!/usr/bin/env bash
# List API key metadata from the MaaS Postgres DB (deployment/postgres).
#
# Plaintext secrets are NOT stored — only key_hash. Minted values appear once
# at create time via the API.
#
# Usage:
#   ./scripts/db-list-api-keys.sh
#   ./scripts/db-list-api-keys.sh --active
#   ./scripts/db-list-api-keys.sh --user kube:admin
#   ./scripts/db-list-api-keys.sh --subscription free
#   ./scripts/db-list-api-keys.sh --counts
#   ./scripts/db-list-api-keys.sh --hash   # include key_hash column
#   DB_NS=redhat-ai-gateway-infra ./scripts/db-list-api-keys.sh
#
# Source: [List Postgres API keys](36ab7044-1cdd-4d6b-b939-17005aa3fd24)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

MODE="list"
FILTER_USER=""
FILTER_SUB=""
FILTER_STATUS=""
SHOW_HASH=0
LIMIT="${LIMIT:-100}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Query api_keys in the POC Postgres (deploy/${POSTGRES_DEPLOY}).

  --active              status = 'active'
  --revoked             status = 'revoked'
  --expired             status = 'expired'
  --user NAME           filter by username
  --subscription NAME   filter by subscription column
  --counts              status histogram only
  --hash                include key_hash in output
  --sql                 print SQL and exit (dry run)
  -h, --help

Env:
  DB_NS / MAAS_API_NS   Postgres namespace (auto-detect)
  POSTGRES_DEPLOY       Default: postgres
  POSTGRES_USER/DB      Default: maas / maas
  LIMIT                 Max rows (default: 100)
EOF
}

PRINT_SQL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --active) FILTER_STATUS=active; shift ;;
    --revoked) FILTER_STATUS=revoked; shift ;;
    --expired) FILTER_STATUS=expired; shift ;;
    --user) FILTER_USER="${2:?}"; shift 2 ;;
    --subscription) FILTER_SUB="${2:?}"; shift 2 ;;
    --counts) MODE=counts; shift ;;
    --hash) SHOW_HASH=1; shift ;;
    --sql) PRINT_SQL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

NS="$(detect_db_ns)"
info "Postgres: ${NS}/deploy/${POSTGRES_DEPLOY} (db=${POSTGRES_DB} user=${POSTGRES_USER})"

if [[ "$MODE" == "counts" ]]; then
  SQL="SELECT status, count(*) FROM api_keys GROUP BY status ORDER BY status;"
else
  COLS="id, username, name, subscription, tenant, status,
       array_to_string(user_groups, ', ') AS groups,
       ephemeral, created_at, expires_at, last_used_at"
  if [[ "$SHOW_HASH" -eq 1 ]]; then
    COLS="id, username, name, key_hash, subscription, tenant, status,
       array_to_string(user_groups, ', ') AS groups,
       ephemeral, created_at, expires_at, last_used_at"
  fi

  WHERE="TRUE"
  [[ -n "$FILTER_STATUS" ]] && WHERE+=" AND status = '${FILTER_STATUS}'"
  [[ -n "$FILTER_USER" ]] && WHERE+=" AND username = '${FILTER_USER//\'/\'\'}'"
  [[ -n "$FILTER_SUB" ]] && WHERE+=" AND subscription = '${FILTER_SUB//\'/\'\'}'"

  SQL="SELECT ${COLS}
FROM api_keys
WHERE ${WHERE}
ORDER BY created_at DESC
LIMIT ${LIMIT};"
fi

if [[ "$PRINT_SQL" -eq 1 ]]; then
  echo "$SQL"
  exit 0
fi

echo
db_psql -c "$SQL"

echo
echo "Note: plaintext API keys are not in the DB (only key_hash)."
echo "Interactive shell: ./scripts/db-shell.sh"
