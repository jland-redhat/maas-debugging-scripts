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

### Option A — Global symlink (recommended for local clone)

Cursor loads user skills from `~/.cursor/skills/<name>/`. The folder name must
be `maas-debugging` (matches the skill `name`).

```bash
git clone <THIS_REPO_URL> ~/src/maas-debugging-scripts   # or your preferred path
ln -sfn ~/src/maas-debugging-scripts ~/.cursor/skills/maas-debugging
```

Verify: **Customize → Skills** (or type `/maas-debugging` in Agent chat).

To update later: `git -C ~/src/maas-debugging-scripts pull`.

### Option B — Clone directly into the skills directory

```bash
git clone <THIS_REPO_URL> ~/.cursor/skills/maas-debugging
```

### Option C — Cursor “Remote Rule (GitHub)”

1. Open **Customize** in the sidebar  
2. **Rules** → **Add Rule**  
3. Select **Remote Rule (Github)**  
4. Paste this repository’s GitHub URL  

Cursor syncs the skill (including `scripts/` and `lib/`) from the repo.

### Option D — Project-only (this repo as the workspace)

If you open this repo as your Cursor workspace and still want project-scoped
discovery without a global install:

```bash
mkdir -p .cursor/skills
ln -sfn ../.. .cursor/skills/maas-debugging
```

(Prefer Option A/B for use while working in *other* MaaS repos like
`maas-billing`.)

### Uninstall

```bash
rm ~/.cursor/skills/maas-debugging    # symlink or clone
# If Option B was a full clone, that deletes the clone — back up first if needed.
```

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
