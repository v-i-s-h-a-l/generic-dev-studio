---
name: Worktree marker
description: Per-worktree manifest schema for interactive and chain worktrees under ~/.dev-studio/<project>/worktrees/<slug>/. Stamped at creation, heartbeat-touched on every owning-command turn, consumed by studio-worktree-gc and manager-cleanup to decide reap-safety.
type: contract
schema_version: 1
---

# Worktree marker

Every studio-owned worktree carries a marker file at:

```
~/.dev-studio/<project>/worktrees/<slug>/.studio-worktree.json
```

The marker is the single source of truth for "is this worktree still in use?"
The gc layer (`scripts/studio-worktree-gc.sh`) and the user-facing cleanup
front-end (`scripts/manager-cleanup.sh`) read it; the owning command (ingest,
plan-chain, work-chain, task-worktree-setup) writes and heartbeats it.

Liveness checks rely on `last_touched` plus presence of an active chain or
session in run-state, **not** on pid probes. Crashed sessions therefore become
reapable on the next gc pass once their staleness exceeds the TTL.

## Shape

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | integer | yes | Always `1` today. |
| `kind` | enum | yes | `ingest` \| `plan` \| `chain` \| `worker`. |
| `slug` | string | yes | Basename of the worktree directory. |
| `project` | string | yes | Project slug (`resolve_project` of the main checkout). |
| `created_at` | ISO-8601 UTC | yes | Stamped once at worktree creation. |
| `last_touched` | ISO-8601 UTC | yes | Updated on every owning-command turn. |
| `session_id` | string \| null | no | Manager session id for ingest/plan kinds. |
| `chain_id` | string \| null | no | Chain-run id for chain/worker kinds. |
| `task_id` | string \| null | no | Task id for worker kind. |
| `host` | string \| null | no | Canonical host id (`claude-code`, `codex`). |
| `pid` | integer \| null | no | Informational only — gc never probes liveness. |

The authoritative schema is
[`worktree-marker.schema.json`](worktree-marker.schema.json).

## Write path

`scripts/lib-worktree-marker.sh` is the shared writer:

- `worktree_marker_write <worktree> <kind> [<id-flag> <id-value> ...]` —
  writes the marker; idempotent — re-writing preserves `created_at`.
- `worktree_marker_touch <worktree>` — updates `last_touched` only; never
  rewrites the rest of the marker. Owning commands call this on every turn.
- `worktree_marker_read <worktree> <field>` — extracts a single field; uses
  `jq` when present, falls back to a small awk reader so the gc still runs
  on hosts without `jq`.

The library deliberately exposes no remove primitive — worktree removal is
the owning command's responsibility (or `studio-worktree-gc.sh`'s when
reaping). Removing the marker without removing the worktree is never a
correct operation.

## GC contract

`scripts/studio-worktree-gc.sh` walks `~/.dev-studio/<project>/worktrees/` and
considers a worktree reapable when all of the following hold:

1. A valid marker file exists.
2. `now - last_touched > ttl_seconds` (default 7 days,
   `--ttl-days` overrides, `STUDIO_WORKTREE_GC_TTL_DAYS` env overrides).
3. No matching active chain or session is recorded in run-state for the
   marker's `chain_id` / `session_id` (`chain-run-state.sh` integration is
   delegated to whatever active-id source the host has; the gc accepts a
   `--active-ids <csv>` shortlist and treats unmatched markers as reapable).
4. The marker's `slug` is not in `STUDIO_KEEP_WORKTREE` (comma-separated
   user override; assistants must not set it on their own initiative).

The default mode is dry-run / report-only. `--reap` performs `git worktree
remove --force` and then `rm -rf` of any leftover marker dir. The script
emits structured JSON on stdout and human-friendly lines on stderr — it is
safe to pipe stdout into `jq`.

### Disk-budget alarm

`studio-worktree-gc.sh --budget-check` emits an alarm record when either of
the following thresholds is crossed:

- Total worktree footprint (in bytes) exceeds
  `STUDIO_WORKTREE_DISK_BUDGET_BYTES` (default 5 GiB).
- Worktree count exceeds `STUDIO_WORKTREE_COUNT_BUDGET` (default 10).

The alarm record names the candidates that would be reaped under the default
TTL so the user can decide whether to run `manager cleanup --worktrees`.

## Three cleanup layers (the rule this contract serves)

1. **On finalize / abort:** the owning command removes its own worktree as
   part of normal exit. This is the fastest, cheapest path.
2. **On session start:** bootstrap invokes `studio-worktree-gc.sh
   --reap-stale` so crashed sessions cannot accumulate.
3. **Disk-budget alarm:** when stage 2 is not enough,
   `studio-worktree-gc.sh --budget-check` surfaces an actionable warning
   that points the user at `manager cleanup --worktrees`.

The override `STUDIO_KEEP_WORKTREE=<slug>[,<slug>...]` exempts named
worktrees from layers 2 and 3 (layer 1 is the owning command's contract —
the keep-list does not affect explicit finalize).

## Related

- `_shared/standards/branch-discipline.md` — the broader arc this marker
  serves; layer-2 GC is the surface that keeps interactive-session
  isolation from leaking disk.
- `CLAUDE.md` §"Worktree protocol" — the rule that requires interactive
  sessions to take a worktree at all.
- `scripts/task-worktree-setup.sh` — worker-kind worktrees; writes the
  marker via `lib-worktree-marker.sh`.
