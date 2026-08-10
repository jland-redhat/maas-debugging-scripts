#!/usr/bin/env bash
# Interactive psql shell inside the MaaS Postgres deployment.
#
# Usage:
#   ./scripts/db-shell.sh
#   ./scripts/db-shell.sh -c '\dt'
#   DB_NS=opendatahub ./scripts/db-shell.sh
#
# Source: [List Postgres API keys](36ab7044-1cdd-4d6b-b939-17005aa3fd24)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

NS="$(detect_db_ns)"
info "Opening psql on ${NS}/deploy/${POSTGRES_DEPLOY} as ${POSTGRES_USER}@${POSTGRES_DB}"
info "Handy: \\dt   SELECT id, username, name, status FROM api_keys ORDER BY created_at DESC LIMIT 20;"

# -it when no -c args (interactive). If caller passed -c / other psql flags, no TTY needed.
if [[ $# -eq 0 ]]; then
  "$KUBECTL" exec -it -n "$NS" "deploy/${POSTGRES_DEPLOY}" -- \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
else
  db_psql "$@"
fi
