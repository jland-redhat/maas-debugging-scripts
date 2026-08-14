# maas-debugging

Cursor Agent Skill + shell toolbox for debugging **Models-as-a-Service** (MaaS)
on OpenShift / RHOAI / ODH.

This repository **is** the skill: one `SKILL.md`, one `scripts/` tree, one
`lib/`. Agents should run these scripts instead of inventing curls (saves tokens).

```text
.
├── SKILL.md          # agent instructions
├── lib/common.sh     # shared helpers
├── scripts/          # executable debug recipes
└── README.md         # humans + install
```

Requires: `oc` or `kubectl`, `curl`, `jq`, `python3`.

---

## Install the skill

You do **not** need to manually `git clone` this repo. Prefer A or B.

### Option A — `npx skills` (no manual clone)

Installs the skill (including `scripts/` + `lib/`) into your agent skills dir:

```bash
# Global (available in every workspace)
npx skills add jland-redhat/maas-debugging-scripts -g

# Or project-local (current workspace only)
npx skills add jland-redhat/maas-debugging-scripts
```

Update later with `npx skills check` / `npx skills update` (see [skills.sh](https://skills.sh)).


### Option B — Cursor UI: Remote Rule (GitHub)

Cursor fetches/syncs the repo for you (you don’t clone by hand):

1. **Customize** (sidebar) → **Rules** → **Add Rule**
2. **Remote Rule (Github)**
3. Paste: `https://github.com/jland-redhat/maas-debugging-scripts`

Per [Cursor docs](https://cursor.com/docs/skills), this is the built-in GitHub
import path. **Caveat:** some builds treat this importer as Rules (`.mdc`) and
skills may not show under **Skills** / Agent context even though files synced —
if that happens, use Option A or C.

### Option C — Manual clone / symlink (contributors)

Use this when you want a writable checkout to fix/add scripts:

```bash
git clone git@github.com:jland-redhat/maas-debugging-scripts.git ~/src/maas-debugging-scripts
ln -sfn ~/src/maas-debugging-scripts ~/.cursor/skills/maas-debugging
```

Or clone straight into the skills dir:

```bash
git clone git@github.com:jland-redhat/maas-debugging-scripts.git ~/.cursor/skills/maas-debugging
```

Folder name must be `maas-debugging` (matches skill `name` in `SKILL.md`).

Verify: **Customize → Skills**, or type `/maas-debugging` in Agent chat.

### Uninstall

```bash
# After npx / clone into skills dir:
rm -rf ~/.cursor/skills/maas-debugging

# Symlink only (Option C):
rm ~/.cursor/skills/maas-debugging
```

Remove any matching **Remote Rule** entry under **Customize → Rules** if you used Option B.

---

## Quick start (after install)

```bash
export KUBECONFIG=/path/to/kubeconfig   # optional

SKILL=~/.cursor/skills/maas-debugging
"$SKILL/scripts/print-envoy-filters.sh" --stats
"$SKILL/scripts/mint-and-chat.sh"
"$SKILL/scripts/burst-inference.sh" --count 10
```

Or from a clone checkout:

```bash
./scripts/print-resource-generations.sh
./scripts/mint-and-chat.sh
```

### Common env

| Env | Default | Purpose |
|-----|---------|---------|
| `GW_NS` / `GW_NAME` | `openshift-ingress` / `maas-default-gateway` | Gateway |
| `MAAS_GATEWAY_HOST` | auto | e.g. `https://maas.apps....` |
| `MAAS_API_NS` / `DB_NS` | auto | Infra / Postgres NS |
| `API_KEY` | (mint) | Skip mint for inference scripts |
| `KUBECTL` | `oc` or `kubectl` | Client |

---

## Scripts

| Script | Use when |
|--------|----------|
| `print-resource-generations.sh` | Gateway/EnvoyFilter `metadata.generation` churn (OOM / RHOAIENG-81865) |
| `print-envoy-filters.sh` | Live Envoy `http_filters` (+ `--stats`) |
| `inventory-envoyfilters.sh` | Intended EF / WasmPlugin CRs |
| `check-istiod-skips.sh` | Why an EnvoyFilter did not apply |
| `probe-body-routing.sh` | Body-only vs `X-Gateway-Model-Name` (404 NR) |
| `check-auth-stack.sh` | AuthPolicy / Authorino / NP |
| `mint-and-chat.sh` | Mint key → models → one chat/completions |
| `burst-inference.sh` | Many calls + running token tally |
| `probe-streaming.sh` | Validate SSE `stream=true` chat/completions |
| `probe-large-io.sh` | Large prompt + large completion; nonstream and stream |
| `db-list-api-keys.sh` | `api_keys` rows in Postgres (`key_hash` only) |
| `db-shell.sh` | Interactive `psql` |
| `db-show-config.sh` | DB secrets / redacted DSN / sslmode |

### Symptom cheat sheet

| Symptom | Start with |
|---------|------------|
| Gateway OOM / config churn | `print-resource-generations.sh` |
| `404 NR` / body routing | `print-envoy-filters.sh`, `probe-body-routing.sh` |
| Auth / key mint fail | `check-auth-stack.sh`, `mint-and-chat.sh` |
| Keys in DB | `db-list-api-keys.sh` |
| Rate-limit / token burn | `burst-inference.sh` |
| Streaming SSE | `probe-streaming.sh` |
| Large request/response (both modes) | `probe-large-io.sh` |
| Smoke | `mint-and-chat.sh` |

---

## Adding scripts

The skill instructs the agent to:

1. **Recommend** a new script when triage hits a reusable gap (and offer to write it here).
2. **Notify you** when an existing script fails, with a short breakdown
   (command, expected vs got, likely cause, suggested repo fix) so it can be
   corrected quickly.

When adding manually:

1. Add `scripts/your-recipe.sh` (source `../lib/common.sh`).  
2. Update the symptom table in `SKILL.md` and this README.  
3. Keep scripts env-overridable; prefer running them over ad-hoc curls.
