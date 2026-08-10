# MaaS Debugging Scripts

Personal toolbox of small, reusable scripts for debugging Models-as-a-Service
(RHOAI / ODH) on OpenShift. Captured from day-to-day cluster triage.

## Quick start

```bash
export KUBECONFIG=/path/to/kubeconfig   # optional
./scripts/print-resource-generations.sh
./scripts/print-envoy-filters.sh --stats
./scripts/mint-and-chat.sh
```

All scripts prefer `oc`, fall back to `kubectl`. Common overrides:

| Env | Default | Purpose |
|-----|---------|---------|
| `GW_NS` / `GW_NAME` | `openshift-ingress` / `maas-default-gateway` | Gateway API gateway |
| `EF_NS` | same as `GW_NS` | EnvoyFilter namespace |
| `MAAS_GATEWAY_HOST` | auto | e.g. `https://maas.apps....` |
| `MAAS_API_NS` | auto | `redhat-ai-gateway-infra` or `odh-ai-gateway-infra` |
| `DB_NS` | auto | Namespace for `deploy/postgres` |
| `KUBECTL` | `oc` or `kubectl` | Client binary |

## Scripts

### Resource churn (“generations”)

`metadata.generation` on Gateways / EnvoyFilters — **not** LLM tokens.
Signal for [RHOAIENG-81865](https://issues.redhat.com/browse/RHOAIENG-81865)
(EnvoyFilter leakage → gateway OOM).

```bash
./scripts/print-resource-generations.sh
./scripts/print-resource-generations.sh --watch 5
GATEWAY=kuadrant-maas-default-gateway GATEWAY_NS=openshift-ingress \
  ./scripts/print-resource-generations.sh --detail
```

Quiet ≈ generation `1`. Thousands quickly ⇒ reconcile loop.

### Live Envoy filter chain

Confirm what the gateway pod actually has loaded (CRs can lie):

```bash
./scripts/print-envoy-filters.sh
./scripts/print-envoy-filters.sh --stats
./scripts/print-envoy-filters.sh --dump /tmp/gw-config.json
```

Expected shape (names vary by RHCL version): `ipp-pre` → auth (`wasm`) → `ipp` → `router`.

Inventory intended config (EnvoyFilter / WasmPlugin only):

```bash
./scripts/inventory-envoyfilters.sh
./scripts/check-istiod-skips.sh
```

### Body routing A/B (404 NR)

```bash
./scripts/probe-body-routing.sh publishers/llm/models/my-model
```

Header works + body-only 404 ⇒ missing/broken `ipp-pre`.

### Mint API key + generation (chat/completions)

```bash
./scripts/mint-and-chat.sh
./scripts/mint-and-chat.sh llm-simulator
./scripts/mint-and-chat.sh --endpoint completions
```

Flow: OC token → `POST /maas-api/v1/api-keys` → `GET /maas-api/v1/models` →
`POST …/v1/chat/completions`. Deletes the key on exit unless `--keep-key`.

### Auth stack inventory

When key mint fails (`AUTH_FAILURE`, missing `X-MaaS-Username`):

```bash
./scripts/check-auth-stack.sh
./scripts/check-auth-stack.sh --logs
```

### Postgres / API keys in the DB

POC Postgres (`deploy/postgres`, usually under the infra NS). Lists **metadata**
only — plaintext secrets are never stored (`key_hash` only).

```bash
./scripts/db-list-api-keys.sh
./scripts/db-list-api-keys.sh --active
./scripts/db-list-api-keys.sh --user kube:admin
./scripts/db-list-api-keys.sh --counts
./scripts/db-shell.sh                 # interactive psql
./scripts/db-show-config.sh           # secrets + redacted DSN / sslmode
```

Override namespace with `DB_NS=…` if auto-detect misses.

## Symptom → script

| Symptom | Start with |
|---------|------------|
| Gateway OOM / config churn | `print-resource-generations.sh` |
| `404 NR` / body routing | `print-envoy-filters.sh`, `probe-body-routing.sh` |
| Auth 401/403 / key mint fail | `check-auth-stack.sh`, then `mint-and-chat.sh` |
| “What’s in the DB for keys?” | `db-list-api-keys.sh` / `db-shell.sh` |
| maas-api DB / TLS connect fail | `db-show-config.sh` |
| “Is IPP even loaded?” | `inventory-envoyfilters.sh` → `print-envoy-filters.sh` |
| EF not applying | `check-istiod-skips.sh` |
| End-to-end smoke | `mint-and-chat.sh` |

## Origins

Recipes distilled from:

- [EnvoyFilter generations triage](b8d27d3d-c909-43f6-84a8-f8c2601eed29) (RHOAIENG-81865 / Slack)
- [Praxis IPP deploy](d80b251b-9104-4653-842b-3e30ade8b7a5) (API key / models / validate path)
- [List Postgres API keys](36ab7044-1cdd-4d6b-b939-17005aa3fd24)
- `personal-knowledge-base/maas/gateway-debugging`
- `maas-billing/scripts/check-payload-ext-proc-filters.sh` + `validate-deployment.sh`

## Adding scripts

Keep them small, env-overridable, and documented in this README.
Share helpers via `lib/common.sh`. Prefer `oc`/`kubectl` + `curl`/`jq`/`python3`.
