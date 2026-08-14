# MaaS Debugging Scripts

Personal toolbox for debugging Models-as-a-Service (RHOAI / ODH) on OpenShift.

**Canonical location (ships with the Cursor skill):**

```text
.cursor/skills/maas-debugging/
  SKILL.md
  lib/
  scripts/
```

Repo-root `scripts/` and `lib/` are symlinks into that skill folder so
`./scripts/...` still works when you clone the repo.

**Cursor skill:** `maas-debugging` — install from this GitHub repo (or symlink
into `~/.cursor/skills/`). The skill folder includes the scripts, so agents
run known-good tooling instead of inventing curls (saves tokens).

## Quick start

```bash
export KUBECONFIG=/path/to/kubeconfig   # optional

# From repo root (via symlink):
./scripts/print-resource-generations.sh
./scripts/print-envoy-filters.sh --stats
./scripts/mint-and-chat.sh
./scripts/burst-inference.sh --count 10

# Or from the skill directory after a Cursor/GitHub install:
#   ~/.cursor/skills/maas-debugging/scripts/...
```

Requires: `oc` or `kubectl`, `curl`, `jq`, `python3`.

### Common env

| Env | Default | Purpose |
|-----|---------|---------|
| `GW_NS` / `GW_NAME` | `openshift-ingress` / `maas-default-gateway` | Gateway API gateway |
| `EF_NS` | same as `GW_NS` | EnvoyFilter namespace |
| `MAAS_GATEWAY_HOST` | auto | e.g. `https://maas.apps....` |
| `MAAS_API_NS` | auto | `redhat-ai-gateway-infra` or `odh-ai-gateway-infra` |
| `DB_NS` | auto | Namespace for `deploy/postgres` |
| `KUBECTL` | `oc` or `kubectl` | Client binary |
| `API_KEY` | (mint) | Skip mint for inference scripts |

## Scripts

### Resource churn (“generations”)

Kubernetes `metadata.generation` on Gateways / EnvoyFilters — **not** LLM tokens
([RHOAIENG-81865](https://issues.redhat.com/browse/RHOAIENG-81865)).

```bash
./scripts/print-resource-generations.sh
./scripts/print-resource-generations.sh --watch 5
```

### Live Envoy filter chain

```bash
./scripts/print-envoy-filters.sh
./scripts/print-envoy-filters.sh --stats
./scripts/inventory-envoyfilters.sh
./scripts/check-istiod-skips.sh
```

### Body routing A/B (404 NR)

```bash
./scripts/probe-body-routing.sh publishers/llm/models/my-model
```

### Mint API key + one chat

```bash
./scripts/mint-and-chat.sh
./scripts/mint-and-chat.sh llm-simulator
```

### Burst inference + running token tally

```bash
./scripts/burst-inference.sh
./scripts/burst-inference.sh llm-simulator --count 20 --stop-on-429
```

### Auth stack

```bash
./scripts/check-auth-stack.sh --logs
```

### Postgres / API keys in the DB

Metadata only (`key_hash` — no plaintext secrets).

```bash
./scripts/db-list-api-keys.sh
./scripts/db-list-api-keys.sh --active --user kube:admin
./scripts/db-shell.sh
./scripts/db-show-config.sh
```

## Symptom → script

| Symptom | Start with |
|---------|------------|
| Gateway OOM / config churn | `print-resource-generations.sh` |
| `404 NR` / body routing | `print-envoy-filters.sh`, `probe-body-routing.sh` |
| Auth 401/403 / key mint fail | `check-auth-stack.sh`, then `mint-and-chat.sh` |
| Keys in DB | `db-list-api-keys.sh` / `db-shell.sh` |
| maas-api DB / TLS | `db-show-config.sh` |
| IPP loaded? | `inventory-envoyfilters.sh` → `print-envoy-filters.sh` |
| EF not applying | `check-istiod-skips.sh` |
| Smoke | `mint-and-chat.sh` |
| Rate-limit / token burn | `burst-inference.sh` |

## Installing the skill

- **This repo as workspace:** skill is already under `.cursor/skills/maas-debugging/`.
- **Personal / other workspaces:** symlink or copy that folder to
  `~/.cursor/skills/maas-debugging`.
- **From GitHub (Cursor Remote Rule):** point at this repo — the skill directory
  includes `scripts/` + `lib/`, so install gets the executables too.

## Adding scripts

Add under `.cursor/skills/maas-debugging/scripts/`, helpers in `lib/common.sh`,
update `SKILL.md` symptom table and this README.
