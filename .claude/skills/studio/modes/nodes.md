---
name: Studio Nodes
description: Day-2 fleet management — list workers, add/remove/enable/disable, probe health, push manifest, manage scheduled sync. Wraps configure.sh + node-health.sh + sync-worker(s).sh; does not run bootstrap.
type: mode-pack
schema_version: 1
budget_tokens: 400
snapshots: []
reads:
  - ~/.dev-studio/.runtime/nodes.json
  - ~/.dev-studio/<project>/worker-manifest.yaml
writes:
  - ~/.dev-studio/.runtime/nodes.json (via configure.sh worker add/remove/enable/disable)
  - ~/Library/LaunchAgents/dev.studio.worker-sync.plist (via configure.sh schedule)
---

# Mode: Nodes

Fleet management from inside Claude. Onboarding a *new* machine still goes through `/studio-setup` (or `scripts/bootstrap.sh`) — this mode is everything that comes after.

| Sub-command | Wraps | Purpose |
|---|---|---|
| (default, no arg) / `status` | `configure.sh status` + `node-health.sh` + `worker-status.sh` | One-screen fleet snapshot |
| `add` | `configure.sh worker add` (interactive prompts in script) | Register a worker |
| `remove <id>` | `configure.sh worker remove <id>` | Unregister |
| `enable <id>` / `disable <id>` | `configure.sh worker enable\|disable <id>` | Toggle dispatch eligibility |
| `scopes <id> <a,b>` | `configure.sh worker scopes <id> <csv>` | Set credential scopes (e.g. `asc,slack`); empty CSV clears. Consumed by `node-pick --requires-secret-scope`. |
| `health [<id>]` | `node-health.sh [<id>]` | Probe one or all (status + load1) |
| `sync [<id>\|--all] [--dry-run]` | `sync-worker.sh <id>` or `sync-workers-all.sh` | Push manifest deltas |
| `schedule on\|off\|status` | `configure.sh schedule …` | Manage the launchd auto-sync agent |
| `recheck` | `configure.sh recheck` | Re-run role validation on this machine; surface diff vs last bootstrap (e.g. Xcode now installed, SSH key now valid) |

All sub-commands shell out to existing scripts. This mode is dispatch + result rendering, not new logic.

## Step 1 — Default: status

Run all three concurrently and aggregate. Each is sub-second.

```bash
scripts/configure.sh status
scripts/node-health.sh
scripts/worker-status.sh
```

Render as three sections:

| Section | Source | Show |
|---|---|---|
| **Registered workers** | `configure.sh status` (Workers section) | id, host, enabled, roles, user — table form |
| **Health** | `node-health.sh` | id, status (`healthy`/`moved`/`unreachable`/`disabled`), load1, host |
| **Fleet activity** | `worker-status.sh` | per-worker pending tasks, busy/idle, last completion |
| **Schedule** | `configure.sh status` (Scheduled worker-sync section) | active / not scheduled / drift |

If no workers are registered, surface the line `(none — agents-only mode; all dispatches run locally)` and stop. Don't run health or fleet probes.

## Step 2 — Mutations: add / remove / enable / disable

Pass through to `configure.sh worker <sub> [<id>]`. The script handles the prompts (for `add`) or the jq mutation. Surface the script's output verbatim.

For `add`, the wizard prompts inline (id, host, user, roles). If the user passed values like `/studio nodes add --id mini --host mini.local`, prefer non-interactive: open `nodes.json` via jq directly, append the worker, exit. Surface what was added.

After any mutation, re-run `configure.sh status` Workers section so the user sees the new state.

## Step 3 — Health

```bash
scripts/node-health.sh [<id>]
```

Output is parseable: `<id>\t<status>\t<load1>\t<host>` per line. Render as a table. Exit code: 0 = at least one healthy; 1 = none healthy. Surface both. Status values: `healthy`, `moved` (reachable but registry's `machine_id` differs from the remote's — `node_machine_id_drift` event fired; re-register via `configure.sh worker add` to clear), `unreachable`, `disabled`. `moved` is dispatchable — node-pick treats it the same as `healthy`.

## Step 4 — Sync

```bash
# one worker
scripts/sync-worker.sh <id> [--dry-run]
# all workers
scripts/sync-workers-all.sh [--dry-run]
```

The scripts emit `worker_sync_*` events on their own; do not re-emit. Surface drift items (lines tagged `drift_detected`) prominently — those are the actionable findings.

If the user invokes `sync` with no id and no `--all`, ask them to pick: "one worker (`sync <id>`) or all workers (`sync --all`)?" Prefer explicit over implicit.

## Step 5 — Recheck

```bash
scripts/configure.sh recheck
```

Re-runs `validate()` for every step the current role recorded during `bootstrap.sh`. Reports per-step diff vs last-known status. Use after fixing something that previously failed — e.g. you installed Xcode after the wizard reported it missing, or you fixed a bad SSH key. If a previously-failing step now passes, the table flags it `↑ newly passing`. If a previously-passing step now fails, it's flagged `↓ regression`.

Local-only today. Remote recheck (re-validate a registered worker over SSH) is a follow-up.

## Step 6 — Schedule

```bash
scripts/configure.sh schedule on    # install launchd agent
scripts/configure.sh schedule off   # remove
scripts/configure.sh schedule status # show launchd state + last log
scripts/configure.sh schedule run   # one-shot sync now
```

Pass through. The `on`/`off` paths write to `~/Library/LaunchAgents/dev.studio.worker-sync.plist` — that's the one place this mode reaches outside `~/.dev-studio/**`. Per CLAUDE.md it's an explicit, documented system action, so it stays.

## Intent detection

Studio router dispatches here for:

- `/studio nodes` (any sub-command, or none)
- "show the fleet", "list workers", "are the workers up?", "fleet status"
- "register a worker", "add the mini", "add a node"
- "sync the workers", "push the manifest", "is the mini in sync"
- "is the scheduled sync running", "turn off auto-sync"
- "I just installed Xcode — re-check the worker", "recheck", "did anything change?"

Out of scope (route elsewhere):

| User intent | Route to |
|---|---|
| Onboard a new machine for the first time | `/studio-setup` |
| Edit the worker manifest contents | `scripts/configure.sh manifest` (opens in `$EDITOR`) |
| Dispatch a build/test to a specific worker | `scripts/node-dispatch.sh <id> <cmd>` (not a studio mode today) |
| Task-level work (briefs, reviews, builds) | `/chanakya`, `/achilles`, `/argus` |

## Never

- Do not run `scripts/bootstrap.sh`. That's `/studio-setup`'s job. This mode never bootstraps a fresh machine.
- Do not edit `nodes.json` directly with `Edit` or `Write`. Always go through `configure.sh worker …` so jq-based atomic writes and schema integrity hold.
- Do not invent new sync semantics. `sync-worker.sh` and `sync-workers-all.sh` are authoritative.
- Do not silently skip a sub-command if a script is missing — fail loud (per R14).

## Forward-compat

Adding a new sub-command: one row in the table above + one block in the Steps section + one fixture line. Same rule as every other mode pack in this repo.
