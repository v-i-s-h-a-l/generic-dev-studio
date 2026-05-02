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

**Never write outside these two roots.** Specifically: never use `~/.claude/` for runtime state or project secrets — it's the agent's own config dir, outside the allowlist by design. The only `~/.claude/` path agents may *read* is `~/.claude/projects/<slug>/memory/` (Claude Code's own auto-managed area). Project secrets live under `~/.dev-studio/<project>/secrets/`.

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
| Build-debt counter | `~/.dev-studio/<project>/plans/build-debt.yaml` | `_shared/schemas/build-debt.md` |
| Master-plan preamble (editorial) | `~/.dev-studio/<project>/plans/master-plan-preamble.md` | — (free-form; verbatim included by `scripts/render-master-plan.sh`) |
| Master plan (rendered projection) | `~/.dev-studio/<project>/plans/chanakya-master.md` | rendered by `scripts/render-master-plan.sh` from preamble + build-debt + tasks + releases YAML; never hand-edited post-#273 |
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
| Xcodebuild lock (global, per-node, per-slot) | `~/.dev-studio/.runtime/xcodebuild-lock/<node-id>/slot-<n>/` — serializes xcodebuild against the SPM cache + Clang module cache + simulator locks on the node that runs the build. R4-exempted carve-out: keyed by dispatch target so a laptop-local build and a mini-dispatched build don't serialize on each other. Slot count from the node's `parallel_build_slots` field in `nodes.json` (default 1; #218 Stage C / #268) — at 1 the lock path is `slot-1/` and behaviour is bit-identical to the pre-#268 single-holder lock; at N>1 up to N concurrent holders run, each pinned to a distinct slot subdir. | — |
| Build-queue substrate (global, per-node) | `~/.dev-studio/.runtime/build-queue/<node-id>/` — priority queue feeding the per-node xcodebuild slot locks (#266 / #218; slot-aware per #268). Each waiter writes `<rank>-<enqueued_at>-<pid>-<id>.json` with `{id, priority, enqueued_at, pid, role, secret_scope}` and removes it on exit; the first `parallel_build_slots` entries by priority order are eligible to acquire a slot. `release` entries sort ahead of `task`, then `background`, while in-flight lock holders keep their slot. Same R4 carve-out as the lock itself: per-node physical-resource serialization. | — |
| Node registry (global) | `~/.dev-studio/.runtime/nodes.json` — worker nodes reachable over SSH; consumed by `scripts/node-dispatch.sh` / `node-health.sh` / `node-pick.sh`. Recognised fields: `id`, `machine_id`, `host`, `user`, `roles`, `enabled`, optional `parallel_build_slots` (integer, default 1; #268). | — |
| Dispatch registry (global) | `~/.dev-studio/.runtime/dispatch-registry/<uuid>.json` — laptop-side per-dispatch entry (#270) joining `node-dispatch.sh`'s UUID (#269) to its `task_id`, `node`, `dispatched_at`, and terminal `status` (`in-flight` → `passed`/`failed`/`aborted`). Read by #147-C reconnect-and-harvest to recover the result of a dispatch whose laptop disappeared mid-build. R4-exempted: the UUID identifies a `(laptop, dispatch)` pair, not a project. | — |
| Snapshot references | `~/.dev-studio/<project>/snapshots/references/` — canonical reference images for snapshot tests; generated on the node tagged `snapshot-canonical` and pulled locally via `scripts/snapshot-sync.sh` | — |
| Argus result bundles | `/tmp/argus-<task-id>.xcresult` | — |

Queries against the ledger go through `scripts/query-plans.sh --kind=<artifact-kind>` (glob-free; joins via `plans/index.yaml`). Event reads go through `scripts/read-events.sh`. Never glob `plans/**` directly in new code.

### Legacy layout (pre-Phase 2.6, archived)

Pre-2.6 debrief-shaped artifacts moved under `plans/.legacy-archive/` by `scripts/archive-legacy-surfaces.sh` as part of #245 Stage A.4 (2026-04-27). The companion Stage A.5 deleted every internal writer — `lib-ledger.sh::legacy_*_helpers` are stub fail-loud and the dual-write call sites in writers are gone. The archive root is read-only in practice; only migration tools (`migrate-ledger.sh`, `detect-edits.sh`, `verify-ledger.sh`) consult it.

| Artifact | Path | Status |
|---|---|---|
| Master plan | `~/.dev-studio/<project>/plans/chanakya-master.md` | **Live (rendered projection).** Sole writer is `scripts/render-master-plan.sh`, which composes from `plans/{master-plan-preamble.md, build-debt.yaml, tasks/*.yaml, releases/*.yaml}` and runs end-of-sweep. Never hand-edited. Bootstrap legacy projects via `scripts/extract-master-plan-preamble.sh`. |
| Task briefs | `~/.dev-studio/<project>/plans/.legacy-archive/chanakya-tasks/<task-id>-<slug>.md` | Archived (post-#245 A.4). Replaced by `plans/briefs/*.yaml`. |
| Debrief inbox | `~/.dev-studio/<project>/plans/chanakya-inbox/` | Mixed historical content (`assets/`, `*-tests.md`, `*-test-cases.md`, `processed/feedback-attachments/`, design/product reports, scratch notes) stays in place. Debrief-shaped files (`*-debrief.md`, `build-*-debrief.md`, `tf-*-debrief.md`, `release-*-debrief.md`, `processed/*-debrief.md`) are archived under `plans/.legacy-archive/chanakya-inbox/`. New debriefs write to `plans/debriefs/*.yaml`; new test cases live in debrief `tests.added` / `tests.modified`. |
| Test-case artifacts | `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` | Historical/import-only. `scripts/tests-pull-cases.sh` may read these when a pre-#335 task has no YAML test cases; no active writer targets this path. |
| User test manifest | `~/.dev-studio/<project>/plans/user-testing.md` | Read-only post-migration; superseded by `plans/rounds/*.yaml`. |
| Test-flow rounds | `~/.dev-studio/<project>/plans/user-testing-rounds/user-testing-round<N>.md` | Read-only post-migration; superseded by `plans/rounds/*.yaml`. |
| Journey map (optional) | `~/.dev-studio/<project>/journey-map.md` | Unchanged — not in ledger scope. |
| Legacy event files | `~/.dev-studio/<project>/{event-log,events,agents}.{jsonl,log,ndjson}` and `plans/chanakya-events.jsonl` | Read-only post-migration; consolidated into `events/<date>.jsonl`. Migration left the originals in place for recovery; safe to remove in a follow-up sweep. |
| Archive marker | `~/.dev-studio/<project>/plans/.legacy-archive/ARCHIVED.yaml` | Informational marker written by `scripts/archive-legacy-surfaces.sh`. |

**Resolver status.** `resolve_briefs_dir()`, `resolve_chanakya_inbox()`, and `resolve_chanakya_inbox_for()` were retired on 2026-04-22 (#67). The legacy `lib-ledger::legacy_master_plan_*/legacy_inbox_*/legacy_brief_*/legacy_release_log_*` helpers were retired on 2026-04-27 (#245 A.5) — the function names remain as fail-loud stubs (exit 9) so any straggler caller surfaces immediately rather than degenerating to NameError. Migration / one-shot analysis tools that need to read the archived paths compose them directly off `resolve_plans_dir_for()/.legacy-archive/`. New code must target the canonical layout.
