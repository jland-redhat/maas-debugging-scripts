---
name: maas-debugging
description: >-
  Debug Models-as-a-Service (MaaS) on OpenShift / RHOAI / ODH using the
  maas-debugging-scripts toolbox: Envoy filter chains, EnvoyFilter generations
  churn, AuthPolicy/Authorino, API key mint + inference, burst token tallies,
  Postgres api_keys queries, body-routing 404 NR probes. Use when the user is
  debugging MaaS, IPP/Praxis, Kuadrant, Limitador, gateway OOM, API keys,
  rate limits, or asks to run MaaS debug scripts.
---

# MaaS Debugging

Prefer **running scripts from the toolbox** over inventing one-off curls.

## Repo

```text
MAAS_DEBUG_ROOT=/home/jland/Documents/RedHat/maas/maas-debugging-scripts
```

All commands below: `cd "$MAAS_DEBUG_ROOT"` first (or prefix paths).

Requires: `oc` or `kubectl`, `curl`, `jq`, `python3`. Respect `KUBECONFIG` if set.

## Agent rules

1. Map the symptom → script (table below). Run the script; read its output.
2. Do **not** paste large invent-your-own curl blocks when a script already covers it.
3. Pass through env overrides (`MAAS_GATEWAY_HOST`, `DB_NS`, `GW_NAME`, `API_KEY`, …).
4. “Generations” often means Kubernetes `metadata.generation` (RHOAIENG-81865), not LLM tokens — use `print-resource-generations.sh`.
5. Postgres stores `key_hash` only — never expect plaintext API keys in the DB.
6. After fixing something, re-run the same script to confirm.

## Symptom → script

| Symptom | Script |
|---------|--------|
| Gateway OOM / EnvoyFilter churn | `scripts/print-resource-generations.sh` |
| Live Envoy HTTP filter chain | `scripts/print-envoy-filters.sh [--stats]` |
| Intended EF / WasmPlugin inventory | `scripts/inventory-envoyfilters.sh` |
| EF not applying / istiod skip | `scripts/check-istiod-skips.sh` |
| `404 NR` body routing | `scripts/probe-body-routing.sh <MODEL_ID>` |
| Auth / key mint fail | `scripts/check-auth-stack.sh [--logs]` |
| Smoke: mint + one chat | `scripts/mint-and-chat.sh [MODEL]` |
| Burst calls + running token tally | `scripts/burst-inference.sh [--count N]` |
| List API key metadata in DB | `scripts/db-list-api-keys.sh` |
| Interactive `psql` | `scripts/db-shell.sh` |
| DB secrets / sslmode | `scripts/db-show-config.sh` |

## Common env

| Env | Purpose |
|-----|---------|
| `KUBECONFIG` | Target cluster |
| `MAAS_GATEWAY_HOST` | e.g. `https://maas.apps....` |
| `GW_NS` / `GW_NAME` | Default `openshift-ingress` / `maas-default-gateway` |
| `MAAS_API_NS` / `DB_NS` | Infra / Postgres namespace |
| `API_KEY` | Skip mint for inference scripts |
| `OC_TOKEN` | Override `oc whoami -t` |

## Typical triage order

**404 NR / missing IPP**
1. `./scripts/print-envoy-filters.sh --stats`
2. `./scripts/probe-body-routing.sh <model>`
3. `./scripts/inventory-envoyfilters.sh` → `./scripts/check-istiod-skips.sh`

**Key mint / AUTH_FAILURE**
1. `./scripts/check-auth-stack.sh --logs`
2. `./scripts/mint-and-chat.sh`
3. `./scripts/db-list-api-keys.sh --counts` (did anything land?)

**Rate limit / token burn**
1. `./scripts/burst-inference.sh --count 20`
2. Optional: `--stop-on-429`, `--verbose`

**Gateway OOM**
1. `./scripts/print-resource-generations.sh`
2. `--watch 5` if churning live

## Adding scripts

New recipes go in `$MAAS_DEBUG_ROOT/scripts/`, helpers in `lib/common.sh`, and a README row. Keep scripts env-overridable and Podman-first only if containers appear (cluster debug uses `oc`).

## More detail

Full script docs: [README.md](../../../README.md) (repo root relative from this skill) or `$MAAS_DEBUG_ROOT/README.md`.
