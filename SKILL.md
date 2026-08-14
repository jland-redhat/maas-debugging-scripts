---
name: maas-debugging
description: >-
  Debug Models-as-a-Service (MaaS) on OpenShift / RHOAI / ODH using bundled
  shell scripts (Envoy chains, generations churn, AuthPolicy, API keys,
  inference bursts with token tally, streaming SSE, large request/response,
  Postgres). Use when debugging MaaS, IPP/Praxis, Kuadrant, Limitador,
  gateway OOM, API keys, rate limits, streaming, large payloads, or when the
  user asks for MaaS debug scripts. Prefer these scripts over writing new
  curls to save tokens.
---

# MaaS Debugging

**Goal:** minimize token burn. Run the bundled scripts. Do **not** invent
large curl/`oc` blocks when a script already covers the job.

## Layout

This repository **is** the skill (one copy of everything):

```text
<skill-root>/          ← folder containing this SKILL.md
  SKILL.md
  lib/common.sh
  scripts/*.sh
  README.md
```

Resolve `<skill-root>` as the directory that holds this `SKILL.md`.

```bash
SKILL_ROOT="<absolute path to skill root>"
```

## Hard rules for the agent

1. **Map symptom → script** (table below). Execute it with the Shell tool.
2. **Never rewrite** mint / models / chat / envoy-dump / psql recipes as
   ad-hoc curls when a script exists.
3. Pass env overrides (`KUBECONFIG`, `MAAS_GATEWAY_HOST`, `DB_NS`, `API_KEY`, …).
4. “Generations” often means Kubernetes `metadata.generation` (RHOAIENG-81865),
   **not** LLM tokens → `print-resource-generations.sh`.
5. Postgres has `key_hash` only — no plaintext API keys in the DB.
6. After a fix, **re-run the same script** to confirm.
7. **Simulator + large I/O:** if `probe-large-io.sh` detects an llm-d /
   sample simulator and responses stay small, **ask the user** whether to
   update that model’s simulator (e.g. LLMIS `--mode echo`) before patching
   the cluster. Do not silently reconfigure.
8. **Report broken scripts** — if a bundled script fails, misbehaves, or its
   output is wrong/useless for the stated job, **tell the user** (do not
   silently work around it). Use the failure report format below so the repo
   can be fixed quickly.
9. **Grow the toolbox** — if you hit a recurring or non-trivial debug step
   with **no** matching script, recommend adding one (and offer to write it
   in this skill repo). Prefer a small reusable script over a one-off curl
   wall that will be reinvented next session.

### Script failure report (notify the user)

When a script does not work as expected, surface this to the user **before**
or alongside any workaround:

```markdown
**Script failure:** `scripts/<name>.sh`
- **Command:** `<exact invocation including env>`
- **What failed:** <exit code / empty output / wrong result / hang / …>
- **Expected:** <one line>
- **Got:** <short snippet or error; truncate>
- **Likely cause:** <guess if obvious: NS detect, CRD name, flag, cluster skew>
- **Suggested fix in repo:** <e.g. handle missing subscription column; fix istiod deploy name>
```

Continue debugging if needed, but do **not** hide the breakage — the point of
this skill is a maintained script set.

### When to recommend a new script

Recommend (and offer to implement under `scripts/`) when:

- You ran the same multi-step `oc`/`curl`/`jq` sequence more than once, or
- The step is fragile / easy to get wrong (auth headers, admin port-forward,
  DB discovery, token tallies), or
- A gap blocked triage and a named recipe would help next time.

Skip recommending scripts for trivial one-liners or purely cluster-specific
one-offs that will never generalize.

New script checklist: env-overridable, sources `lib/common.sh` when useful,
`--help` or header usage, add a row to the symptom table + `README.md`.

## Full check (setup + suite + report)

When the user asks for a **full check**, **infra setup**, or end-to-end
validation of streaming / large I/O / basic security:

```bash
"$SKILL_ROOT/scripts/full-check.sh"              # apply echo fixtures + run suite
"$SKILL_ROOT/scripts/full-check.sh --skip-setup" # suite only
"$SKILL_ROOT/scripts/full-check.sh --setup-only"
"$SKILL_ROOT/scripts/full-check.sh --teardown"
```

This **only** creates MaaS objects (echo LLMIS + ModelRef + AuthPolicy +
Subscription under `fixtures/fullcheck-echo/`). It preflights that MaaS looks
installed; it does **not** install the platform.

Suite includes: non-stream echo smoke, streaming `--expect-echo`, large I/O
both modes `--expect-echo`, body-routing probe, identity-spoof mint probe,
envoy filter dump. Writes `~/.tmp/maas-fullcheck-*.md`.

## Symptom → script

| Symptom | Run |
|---------|-----|
| Full suite / echo infra | `"$SKILL_ROOT/scripts/full-check.sh"` |
| Apply echo model + sub/auth only | `"$SKILL_ROOT/scripts/setup-fullcheck-infra.sh" --wait` |
| Gateway OOM / EnvoyFilter churn | `"$SKILL_ROOT/scripts/print-resource-generations.sh"` |
| Live Envoy HTTP filter chain | `"$SKILL_ROOT/scripts/print-envoy-filters.sh" --stats` |
| Intended EF / WasmPlugin inventory | `"$SKILL_ROOT/scripts/inventory-envoyfilters.sh"` |
| EF not applying / istiod skip | `"$SKILL_ROOT/scripts/check-istiod-skips.sh"` |
| `404 NR` body routing | `"$SKILL_ROOT/scripts/probe-body-routing.sh" <MODEL_ID>` |
| Auth / key mint fail | `"$SKILL_ROOT/scripts/check-auth-stack.sh" --logs` |
| Smoke: mint + one chat | `"$SKILL_ROOT/scripts/mint-and-chat.sh" [MODEL]` |
| Burst + running token tally | `"$SKILL_ROOT/scripts/burst-inference.sh" --count N` |
| Streaming SSE (+ optional echo integrity) | `"$SKILL_ROOT/scripts/probe-streaming.sh" [--expect-echo]` |
| Large req/resp (stream + nonstream) | `"$SKILL_ROOT/scripts/probe-large-io.sh" [--expect-echo]` |
| Identity spoof on mint | `"$SKILL_ROOT/scripts/probe-identity-spoof.sh"` |
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

**Streaming / SSE** → `probe-streaming.sh` (add `--expect-echo` with echo LLMIS)

**Large body / integrity** → prefer `full-check.sh` or
`probe-large-io.sh --expect-echo` against echo-mode model. If using a random
simulator instead: **ask the user** before patching LLMIS to `--mode echo`.

**End-to-end / “run all the checks”** → `full-check.sh`

**Gateway OOM** → `print-resource-generations.sh` (`--watch 5` if live)

## Adding scripts

Add under `scripts/`, helpers in `lib/common.sh`, update the symptom table above
and `README.md`. If the skill root is a git checkout the user owns, implement
the script there when they agree; otherwise give the proposed path + behavior
so they can land it in this repo.
