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
| `~/.dev-studio/.runtime/` | Machine-global (cross-project) | Only true machine resources — **test-slot semaphore** (`locks/test-slots/`), since simulator count is fixed on the machine, and the **node registry** (`nodes.json`) describing worker machines reachable from this host |

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

### Canonical layout (post-Phase 2.6)

Phase 2.6 introduced a uniform per-artifact YAML layout under `plans/` + a single day-partitioned event log under `events/`. Schemas live in `_shared/schemas/`. The migration that moves legacy state to this layout is `scripts/migrate-ledger.sh` (project-scoped, big-bang, idempotent). First-party migration landed 2026-04-22 on turnip-ios.

| Artifact | Path | Schema |
|---|---|---|
| Root | `~/.dev-studio/<project>/` | — |
| Plans index | `~/.dev-studio/<project>/plans/index.yaml` | `_shared/contracts/plans-index-validator.md` |
| Task artifacts | `~/.dev-studio/<project>/plans/tasks/<task-id>.yaml` | `_shared/schemas/task.md` |
| Brief artifacts | `~/.dev-studio/<project>/plans/briefs/<brief-id>.yaml` | `_shared/schemas/brief.md` |
| Debrief artifacts | `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` | `_shared/schemas/debrief.md` |
| Review artifacts | `~/.dev-studio/<project>/plans/reviews/<review-id>.yaml` | `_shared/schemas/review.md` |
| Round artifacts | `~/.dev-studio/<project>/plans/rounds/<round-id>.yaml` | `_shared/schemas/round.md` |
| Release artifacts | `~/.dev-studio/<project>/plans/releases/<release-id>.yaml` | `_shared/schemas/release.md` |
| Feedback artifacts | `~/.dev-studio/<project>/plans/feedback/<feedback-id>.yaml` | `_shared/schemas/feedback.md` |
| Crash artifacts | `~/.dev-studio/<project>/plans/crashes/<crash-id>.yaml` | `_shared/schemas/crash.md` |
| Event log | `~/.dev-studio/<project>/events/<YYYY-MM-DD>.jsonl` | `_shared/contracts/events.md` |
| Events index | `~/.dev-studio/<project>/events/index.yaml` | — |
| Pre-migration archive | `~/.dev-studio/<project>/archive/2026-pre-2.6/` | frozen |
| Worktrees | `~/.dev-studio/<project>/worktrees/<task-id>/` | — |
| Locks | `~/.dev-studio/<project>/locks/` | — |
| Per-task DerivedData | `/tmp/derived-data/<task-id>/` | — |
| Project memory | `~/.claude/projects/<sluggified-repo-path>/memory/` — e.g. `/Users/you/work/foo-app` → `-Users-you-work-foo-app`. Claude Code manages this dir automatically per project. | — |
| Review files (legacy archive) | `<project-memory>/reviews/review_<task-id>.md` | — |
| Review archive (legacy) | `<project-memory>/reviews/archive/` | — |
| Fleet inbox root | `~/.dev-studio/<project>/.runtime/achilles-inbox/` | — |
| Push queue | `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` | — |
| Test-slot semaphore (global) | `~/.dev-studio/.runtime/locks/test-slots/` | — |
| Node registry (global) | `~/.dev-studio/.runtime/nodes.json` — worker nodes reachable over SSH; consumed by `scripts/node-dispatch.sh` / `node-health.sh` / `node-pick.sh` | — |
| Argus result bundles | `/tmp/argus-<task-id>.xcresult` | — |

Queries against the ledger go through `scripts/query-plans.sh --kind=<artifact-kind>` (glob-free; joins via `plans/index.yaml`). Event reads go through `scripts/read-events.sh`. Never glob `plans/**` directly in new code.

### Legacy layout (pre-Phase 2.6, preserved)

Kept for historical reads on migrated projects — the directories still hold pre-cutover artifacts (and `chanakya-inbox/processed/` per Q18 archive-as-is). They are no longer written to.

| Artifact | Path (legacy) | Status |
|---|---|---|
| Master plan | `~/.dev-studio/<project>/plans/chanakya-master.md` | Read-only post-migration; replaced by `plans/index.yaml` + `plans/tasks/*.yaml`. |
| Task briefs | `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md` | Read-only post-migration; replaced by `plans/briefs/*.yaml`. Direct-path access only (no resolver — #67 retired `resolve_briefs_dir()` on 2026-04-22). |
| Debrief inbox | `~/.dev-studio/<project>/plans/chanakya-inbox/` | Still holds `assets/` + `*-tests.md` (not migrated by 2.6). `processed/*-debrief.md` preserved per Q18. New debriefs write to `plans/debriefs/*.yaml`. Direct-path access only (no resolver — #67 retired `resolve_chanakya_inbox[_for]()` on 2026-04-22). |
| Test-case artifacts | `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` | Still written here (migration didn't scope test-case artifacts). |
| User test manifest | `~/.dev-studio/<project>/plans/user-testing.md` | Read-only post-migration; superseded by `plans/rounds/*.yaml`. |
| Test-flow rounds | `~/.dev-studio/<project>/plans/user-testing-rounds/user-testing-round<N>.md` | Read-only post-migration; superseded by `plans/rounds/*.yaml`. |
| Journey map (optional) | `~/.dev-studio/<project>/journey-map.md` | Unchanged — not in ledger scope. |
| Legacy event files | `~/.dev-studio/<project>/{event-log,events,agents}.{jsonl,log,ndjson}` and `plans/chanakya-events.jsonl` | Read-only post-migration; consolidated into `events/<date>.jsonl`. Migration left the originals in place for recovery; safe to remove in a follow-up sweep. |

**Resolver status.** The deprecated `resolve_briefs_dir()`, `resolve_chanakya_inbox()`, and `resolve_chanakya_inbox_for()` were retired on 2026-04-22 (#67) after `scripts/detect-edits.sh`, `scripts/achilles-worker.sh`, and `scripts/analyze-collect.sh` upgraded to the YAML shape. Runtime scripts that still need to read the legacy paths (analysis/backfill tools) compose them directly off `resolve_project_root_for()` and emit `legacy_artifact_read` on fallback. New code must target the canonical layout.
