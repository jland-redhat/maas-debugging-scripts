#!/usr/bin/env bash
# Show MaaS DB wiring: postgres deploy location, secrets present, redacted DSN / sslmode.
#
# Useful when maas-api fails with "server refused TLS" / connection errors.
#
# Usage:
#   ./scripts/db-show-config.sh
#   DB_NS=redhat-ai-gateway-infra ./scripts/db-show-config.sh
#
# Sources: postgres-creds / maas-db-config triage chats

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

NS="$(detect_db_ns)"
info "DB namespace: ${NS}"

echo
info "Postgres deploy / pods"
"$KUBECTL" get deploy,svc,pods -n "$NS" -l app=postgres 2>/dev/null \
  || "$KUBECTL" get deploy,svc "$POSTGRES_DEPLOY" -n "$NS" 2>/dev/null \
  || warn "deploy/${POSTGRES_DEPLOY} details unavailable"

echo
info "Secret postgres-creds (keys only + user/db)"
if "$KUBECTL" get secret postgres-creds -n "$NS" >/dev/null 2>&1; then
  "$KUBECTL" get secret postgres-creds -n "$NS" -o json | python3 -c '
import json,sys,base64
o=json.load(sys.stdin)
data=o.get("data") or {}
print("  keys:", sorted(data.keys()))
for k in ("POSTGRES_USER","POSTGRES_DB"):
  if k in data:
    print(f"  {k}=", base64.b64decode(data[k]).decode())
print("  POSTGRES_PASSWORD=", "(set)" if "POSTGRES_PASSWORD" in data else "(missing)")
'
else
  warn "postgres-creds not found in ${NS}"
fi

echo
info "Secret maas-db-config (redacted DSN)"
if "$KUBECTL" get secret maas-db-config -n "$NS" >/dev/null 2>&1; then
  "$KUBECTL" get secret maas-db-config -n "$NS" -o json | python3 -c '
import json,sys,base64,re
o=json.load(sys.stdin)
data=o.get("data") or {}
print("  keys:", sorted(data.keys()))
raw=data.get("DB_CONNECTION_URL")
if not raw:
  print("  DB_CONNECTION_URL: (missing)")
  sys.exit(0)
url=base64.b64decode(raw).decode()
redacted=re.sub(r":([^:@/]+)@", ":***@", url)
print("  DB_CONNECTION_URL=", redacted)
m=re.search(r"sslmode=([^&]+)", url)
print("  sslmode=", m.group(1) if m else "(unset)")
'
else
  warn "maas-db-config not found in ${NS}"
  # Often lives with maas-api while postgres is elsewhere — scan candidates
  info "Scanning other namespaces for maas-db-config…"
  "$KUBECTL" get secret -A -o json 2>/dev/null | python3 -c '
import json,sys
for i in json.load(sys.stdin).get("items",[]):
  if i.get("metadata",{}).get("name")=="maas-db-config":
    m=i["metadata"]
    print("  found in", m.get("namespace"))
' || true
fi

echo
info "Also check maas-api env for DB_CONNECTION_URL source"
MAAS_API_NS="$(detect_maas_api_ns 2>/dev/null || echo "")"
if [[ -n "$MAAS_API_NS" ]]; then
  "$KUBECTL" get deploy maas-api -n "$MAAS_API_NS" -o json 2>/dev/null | python3 -c '
import json,sys
try:
  o=json.load(sys.stdin)
except Exception:
  sys.exit(0)
for c in o.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[]):
  name=c.get("name") or ""
  if name != "maas-api" and "maas-api" not in name:
    continue
  print("  container=", name)
  for e in c.get("env") or []:
    if e.get("name") in ("DB_CONNECTION_URL","DATABASE_URL","PGHOST"):
      if "valueFrom" in e:
        print(" ", e["name"], "from", e["valueFrom"])
      else:
        print(" ", e["name"], "=(literal set)")
' 2>/dev/null || true
fi

echo
echo "Hint: POC Postgres often needs sslmode=disable on maas-db-config if API complains about TLS."
echo "List keys: ./scripts/db-list-api-keys.sh"
