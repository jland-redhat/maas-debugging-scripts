---
name: maas-debugging
description: >-
  Debug Models-as-a-Service (MaaS) on OpenShift / RHOAI / ODH using bundled
  shell scripts (Envoy chains, generations churn, AuthPolicy, API keys,
  inference bursts with token tally, Postgres). Use when debugging MaaS,
  IPP/Praxis, Kuadrant, Limitador, gateway OOM, API keys, rate limits, or
  when the user asks for MaaS debug scripts. Prefer these scripts over
  writing new curls to save tokens.
---

# MaaS Debugging

**Goal:** minimize token burn. Run the bundled scripts. Do **not** invent
large curl/`oc` blocks when a script already covers the job.

## Skill layout (scripts ship with the skill)

```text
<skill-root>/                 ← directory containing this SKILL.md
  SKILL.md
  lib/common.sh
  scripts/*.sh
```

Resolve `<skill-root>` as the folder that holds this `SKILL.md` (wherever
Cursor installed the skill: project `.cursor/skills/…`, `~/.cursor/skills/…`,
or a GitHub-synced copy).

```bash
SKILL_ROOT="<skill-root>"   # absolute path to this skill directory
cd "$SKILL_ROOT"            # optional; or call scripts by absolute path
```

## Hard rules for the agent

1. **Map symptom → script** (table below). Execute that script with the Shell tool.
2. **Never rewrite** mint/list-models/chat/envoy-dump/psql recipes as ad-hoc
   curls when a script exists — that wastes tokens and drifts from known-good.
3. Pass env overrides through (`KUBECONFIG`, `MAAS_GATEWAY_HOST`, `DB_NS`,
   `API_KEY`, `GW_NAME`, …). Read `scripts/<name>.sh --help` / header comments
   only if flags are unclear.
4. “Generations” often means Kubernetes `metadata.generation` (RHOAIENG-81865),
   **not** LLM tokens → `print-resource-generations.sh`.
5. Postgres has `key_hash` only — no plaintext API keys in the DB.
6. After a fix, **re-run the same script** to confirm.

Only hand-roll commands when **no** script fits; then keep them tiny and
consider adding a script to this skill afterward.

## Symptom → script

| Symptom | Run |
|---------|-----|
| Gateway OOM / EnvoyFilter churn | `"$SKILL_ROOT/scripts/print-resource-generations.sh"` |
| Live Envoy HTTP filter chain | `"$SKILL_ROOT/scripts/print-envoy-filters.sh" --stats` |
| Intended EF / WasmPlugin inventory | `"$SKILL_ROOT/scripts/inventory-envoyfilters.sh"` |
| EF not applying / istiod skip | `"$SKILL_ROOT/scripts/check-istiod-skips.sh"` |
| `404 NR` body routing | `"$SKILL_ROOT/scripts/probe-body-routing.sh" <MODEL_ID>` |
| Auth / key mint fail | `"$SKILL_ROOT/scripts/check-auth-stack.sh" --logs` |
| Smoke: mint + one chat | `"$SKILL_ROOT/scripts/mint-and-chat.sh" [MODEL]` |
| Burst + running token tally | `"$SKILL_ROOT/scripts/burst-inference.sh" --count N` |
| List API key rows in DB | `"$SKILL_ROOT/scripts/db-list-api-keys.sh"` |
| Interactive `psql` | `"$SKILL_ROOT/scripts/db-shell.sh"` |
| DB secrets / sslmode | `"$SKILL_ROOT/scripts/db-show-config.sh"` |

## Common env

| Env | Purpose |
|-----|---------|
| `KUBECONFIG` | Target cluster |
| `MAAS_GATEWAY_HOST` | e.g. `https://maas.apps....` |
| `GW_NS` / `GW_NAME` | Default `openshift-ingress` / `maas-default-gateway` |
| `MAAS_API_NS` / `DB_NS` | Infra / Postgres namespace |
| `API_KEY` | Skip mint on inference scripts |
| `OC_TOKEN` | Override `oc whoami -t` |

## Typical triage

**404 NR / missing IPP** → `print-envoy-filters.sh --stats` → `probe-body-routing.sh` → `inventory-envoyfilters.sh` / `check-istiod-skips.sh`

**Key mint / AUTH_FAILURE** → `check-auth-stack.sh --logs` → `mint-and-chat.sh` → `db-list-api-keys.sh --counts`

**Rate limit / token burn** → `burst-inference.sh --count 20` (`--stop-on-429` optional)

**Gateway OOM** → `print-resource-generations.sh` (`--watch 5` if live)

## Adding scripts

Put new recipes in `<skill-root>/scripts/`, shared helpers in `lib/common.sh`.
Keep them env-overridable. Update the symptom table in this file.
