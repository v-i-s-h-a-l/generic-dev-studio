---
name: File Locations
description: Canonical project slug computation plus all file paths (events, reviews, snapshots).
type: reference
---

# Shared: File Locations

## Project Slug

Compute once at startup as the basename of the main repo's git toplevel:

```bash
PROJECT=$(basename "$(git -C <repo-root> rev-parse --show-toplevel)")
```

For the Turnip iOS repo this resolves to `turnip-ios`.

## Canonical Roots

All agents read and write under exactly two roots — both inside `~/.dev-studio/` so a single `Read/Write/Edit(~/.dev-studio/**)` allowlist covers everything without permission prompts:

| Root | Scope | Contents |
|---|---|---|
| `~/.dev-studio/<project>/` | Per-project | Plans, worktrees, per-project derived-data, per-project locks, logs, **fleet inbox** (`<project>/.runtime/achilles-inbox/`), **push queue** (`<project>/.runtime/state/push-queue.jsonl`) |
| `~/.dev-studio/.runtime/` | Machine-global (cross-project) | Only true machine resources — **test-slot semaphore** (`locks/test-slots/`), since simulator count is fixed on the machine |

**Split invariant.** Anything that belongs to a single project's workflow goes under `<project>/` — including each project's fleet of Achilles workers (one Chanakya + one worker pool per project). Only resources physically shared by every project on this machine (simulators, eventually shared device pools, future GPU queues) live under `.runtime/`. When in doubt: per-project.

**Never write outside these two roots.** Specifically: never use `~/.claude/` for runtime state — it's the agent's own config dir, outside the allowlist by design. The only `~/.claude/` paths agents may *read* are `~/.claude/secrets/` (narrow allow) and `~/.claude/projects/<slug>/memory/` (Claude Code's own auto-managed area).

When introducing a new artifact type, decide per the split invariant above — default to per-project unless it's a machine-wide physical resource.

## Path Resolution

All scripts source `scripts/lib-paths.sh` and call:

- `resolve_project` — project slug from `ACHILLES_PROJECT` env var or `git rev-parse --show-toplevel` basename
- `resolve_inbox_root` — per-project fleet inbox (`~/.dev-studio/<project>/.runtime/achilles-inbox`); override with `ACHILLES_INBOX_ROOT`
- `resolve_push_queue` — per-project push queue
- `resolve_runtime_global` — machine-global runtime root
- `list_fleet_projects` — enumerate every project with an active fleet (powers `--all-projects` flags)

Cross-project one-offs: set `ACHILLES_PROJECT=<slug>` before invoking any fleet script.

## File Locations

| Artifact | Path |
|---|---|
| Root | `~/.dev-studio/<project>/` |
| Master plan | `~/.dev-studio/<project>/plans/chanakya-master.md` |
| Task briefs | `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md` |
| Debrief inbox | `~/.dev-studio/<project>/plans/chanakya-inbox/` |
| Processed debriefs | `~/.dev-studio/<project>/plans/chanakya-inbox/processed/` |
| Test-case artifacts | `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` |
| User test manifest | `~/.dev-studio/<project>/plans/user-testing.md` |
| Test-flow rounds | `~/.dev-studio/<project>/plans/user-testing-rounds/user-testing-round<N>.md` |
| Journey map (optional) | `~/.dev-studio/<project>/journey-map.md` |
| Worktrees | `~/.dev-studio/<project>/worktrees/<task-id>/` |
| Locks | `~/.dev-studio/<project>/locks/` |
| Per-task DerivedData | `/tmp/derived-data/<task-id>/` |
| Project memory | `~/.claude/projects/<sluggified-repo-path>/memory/` — e.g. `/Users/you/work/foo-app` → `-Users-you-work-foo-app`. Claude Code manages this dir automatically per project; each project gets its own event log and review archive for free. |
| Event log | `<project-memory>/events/<YYYY-MM-DD>.jsonl` |
| Event offset marker | `<project-memory>/events_offset.md` |
| Review files | `<project-memory>/reviews/review_<task-id>.md` |
| Review archive | `<project-memory>/reviews/archive/` |
| Fleet inbox root | `~/.dev-studio/<project>/.runtime/achilles-inbox/` |
| Push queue | `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` |
| Test-slot semaphore (global) | `~/.dev-studio/.runtime/locks/test-slots/` |
| Argus result bundles | `/tmp/argus-<task-id>.xcresult` |
