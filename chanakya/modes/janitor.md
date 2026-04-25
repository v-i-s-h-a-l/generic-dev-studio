---
name: Chanakya Janitor
description: Project-scoped janitor — runs sweep-janitor + fleet-cleanup for the active project, including the gap-#31 local-debt pass (merged worktrees, orphan DerivedData, dead-pid xcodebuild locks). Default is dry-run; --apply commits the deletions.
type: mode-pack
budget_tokens: 500
snapshots: []
reads: []
writes:
  - none in default (dry-run); --apply deletes leftover artifacts only
---

# Mode: Janitor (`/chanakya janitor`)

Sweep stale artifacts for the active project and report what's reclaimable. Default is dry-run; `--apply` is the structural confirmation that actually deletes.

## What it covers

| Pass | Script | Targets |
|---|---|---|
| Project sweep | `scripts/sweep-janitor.sh all` | Worktrees (7d mtime + not in `git worktree list`), feedback assets (archived parents > 30d), orphan assets (no record reference, 7d grace), feedback scaling alerts. |
| Local-debt (issue #31) | `scripts/sweep-janitor.sh local-debt` | Worktrees whose branch is fully merged into `main` regardless of mtime, DerivedData dirs under `~/.dev-studio/.runtime/derived-data/<slug>/` whose worktree is gone, `locks/xcodebuild.lock` whose pid file points at a dead process. |
| Fleet | `scripts/fleet-cleanup.sh` | Stale `.lock` dirs (no live PID), dead `busy` markers (heartbeat > 180s), `done/` entries > 7d, `worker.log` rotation > 5MB. |

`scripts/sweep-janitor.sh all` already includes the `local-debt` sub-command in its loop, so a single dry-run shows everything.

## Step 1 — Dry-run

```bash
scripts/sweep-janitor.sh --dry-run all
scripts/fleet-cleanup.sh --dry-run
```

Report:
- Counts and reclaimable bytes per category (worktrees / DerivedData / locks / fleet artifacts).
- Specific items that will be deleted, one per line, so the user can spot anything that shouldn't go.
- If everything is clean, one line: "Nothing to sweep."

## Step 2 — Apply

Only when the user passes `--apply` or says "go ahead":

```bash
scripts/sweep-janitor.sh all
scripts/fleet-cleanup.sh
```

Both scripts emit `cleanup_completed` on exit; this mode adds no new event names.

## Step 3 — Report

One-line summary per category after the apply pass, plus the freed bytes. Stop. Do not chain into another mode.

## Cross-project sweeps

For a multi-project sweep ("clean up everything across all my projects"), route to `/studio janitor` — it fans the same scripts out across every project under `~/.dev-studio/`.

## Node-side counterpart

Cleanup of artifacts on **remote worker nodes** (orphans the laptop-side janitor can't reach because they live on a different machine) is tracked under issue #152 (`scripts/node-janitor.sh`, `phase-2.7-epic`). When that lands, this mode pack will gain a `--include-nodes` flag that fans out via SSH; until then, this mode is laptop-side only.

## Never

- Do not delete without `--apply`. The user's "minimal-intervention is a hard requirement" rule applies; the flag is the structural confirmation, not an interactive prompt.
- Do not bypass the `safe_delete` / `safe_delete_global` prefix checks in the underlying scripts. Those checks are what keep the janitor from walking off the reservation.
- Do not auto-run on SessionStart. #31 escalated from a janitor that wasn't running enough; the fix is a discoverable on-demand mode, not a silent background sweep that could surprise-delete.
- Do not invent additional sub-commands beyond what `sweep-janitor.sh` already exposes. New cleanup classes go into `sweep-janitor.sh` first; the mode pack picks them up automatically through `all`.
