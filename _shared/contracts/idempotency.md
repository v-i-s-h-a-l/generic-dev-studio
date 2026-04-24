---
name: Idempotency Contract
description: Every writable agent action is idempotent on a stable key. Retries reuse the original key; duplicate detection is producer-side; the event log is best-effort with reader-side dedupe. No locks.
type: reference
---

# Idempotency Contract

Single-user workflows still produce retries — a worker restart, a dispatched task that a user re-submits, a `--wait` flow that the user confirms twice. Without idempotency these become silent double-writes. The contract is cheap to honor and expensive to skip.

## Rules

1. **Every writable action is idempotent on `idempotency_key`.** "Writable" means any message whose effect persists after the session ends: brief creation, debrief, review verdict, master-plan mutation, event append (best-effort — see §5), snapshot refresh, Slack post.
2. **Key construction is deterministic.** `<agent>:<mode>:<stable-subject>:<content-hash>`.
   - `agent` — `chanakya` / `achilles` / `argus` / `luban` / `chiron`.
   - `mode` — the mode-pack name (`brief`, `task`, `review`, …).
   - `stable-subject` — task ID, feedback ID, release tag; something the user / source material binds to and that survives retries. Not timestamps, not UUIDs.
   - `content-hash` — sha1 of the canonical payload (sorted keys, whitespace-normalized). Changes iff the content changes. Reruns on identical input produce the same key.
3. **Producer-side dedupe.** Before every writable action, the producer reads the sink's tail for a matching key.
   - Found → emit `action_deduped` event + no-op. Return the prior artifact's ID so the caller can proceed.
   - Not found → perform the write.
   **No locks.** Single-writer-per-subject is enforced by the upstream state machine (e.g. one Achilles worktree per task).
4. **Retries MUST reuse the original key.** If a producer retries after a crash, it recomputes the key from the same inputs and lands on the same value. Never regenerate a key with `uuidgen` on retry.
5. **Event log is best-effort append.** Appends are not deduped at write time — two writers racing on the same key will both land. Readers (see `event-emission.md`) dedupe on `(producer.agent, idempotency_key)` via `scripts/read-events.sh` when they care. At this project's scale (single-user serial workflow), duplicates are rare; the reader is a thin wrapper rather than a critical path.
6. **Partial-failure recovery.** A producer that crashed mid-write re-runs with the same key. If the first attempt landed, §3 catches it; if it didn't, the retry completes the write.

## Key-construction examples

| Action | `idempotency_key` |
|---|---|
| Chanakya writes brief for T001 with spec hash `a1b2c3d4` | `chanakya:brief:T001:a1b2c3d4` |
| Achilles emits debrief for T001 with debrief hash `e5f6a7b8` | `achilles:task:T001:e5f6a7b8` |
| Argus records `approved` verdict on T001 review hash `12ab34cd` | `argus:review:T001:12ab34cd` |
| Chanakya ingests feedback record F-0042 | `chanakya:ingest:F-0042:<hash>` |

`stable-subject` is chosen so retries on the same subject collide; `content-hash` disambiguates genuine content changes (a revised brief for the same task gets a new key and is a new write).

## Non-idempotent corners — out of scope

- External side effects (Slack posts, TestFlight uploads, App Store submissions) are covered by their own mechanisms (Slack message IDs, ASC request IDs). The envelope's `idempotency_key` still applies to the record the agent writes about those effects.
- User-interactive prompts are out of scope — the user is not a retrying producer.

## What this buys

- Crash recovery without invariant loss. Restart a worker mid-task; the retry is a no-op or completes cleanly.
- Deterministic tests. Same inputs → same key → same observable effect.
- Safe remote orchestration. A cross-machine retry after a sync delay does not double-write.

## Per-step retry classification

Every cross-boundary write in the worker loop, classified for retry behavior. Workers consult this table when deciding whether to re-attempt a failed step or require compensation before re-entry.

| Write | Classification | Rationale |
|---|---|---|
| Debrief emit (`scripts/task-emit-debrief.sh`) | `retry-safe` | Atomic rename (`.tmp` → final path). A failed mid-write leaves a `.tmp` that the next run overwrites cleanly. |
| Worker-report field within debrief | `retry-safe` | Covered by debrief atomicity. The field is part of the same atomic file. |
| Review verdict emit (`scripts/argus-emit-verdict.sh`) | `retry-safe` | Atomic rename, same pattern as debrief. Re-emit lands same verdict file. |
| Event log append (`scripts/emit-event.sh`) | `retry-unsafe` at write; dedup at read | Two concurrent emitters can both land. Reader dedupes on `(task_id, event_type, step_ordinal)` via `scripts/read-events.sh`. See §5. |
| Git merge (`scripts/task-merge.sh`) | `retry-safe` | Content-addressed; re-merging the same commits lands the same SHA. Git rejects a second merge as a no-op if already applied. |
| GH issue mutations (`gh issue close/edit`) | `retry-safe` | GitHub state transitions are idempotent: closing an already-closed issue is a no-op; editing the same label set is a no-op. |
| Snapshot refresh | `retry-safe` | Atomic rename. Identical inputs produce identical snapshot file. |
| Slack posts | `requires-compensation` | Not idempotent. Covered by external Slack message IDs (already documented in §Non-idempotent corners). Do not retry without first checking for a prior message ID. |
| Argus spawn via `dispatch-review.sh` | `retry-unsafe` pre-spawn; `retry-safe` after verdict | Guarded by `--idempotency-key` scan before spawn. See §Dispatch keying. |

### step_ordinal convention

`step_ordinal` is a monotonic integer per `(task_id, event_type)` pair. It is assigned by the emitter (not a central counter) — emitters start at 1 and increment locally. On retry, the emitter re-emits with the same `step_ordinal` it used on the first attempt (derived from attempt number passed by the caller). Readers treat duplicate `(task_id, event_type, step_ordinal)` tuples as a single logical event, keeping the first seen.

## Dispatch keying

`dispatch-review.sh` participates in idempotency through an explicit key scan before every spawn.

### Key format

```
--idempotency-key <task-id>:<stage>:<attempt>
```

- `task-id` — the task identifier (e.g. `T001`).
- `stage` — `spec-compliance` or `code-quality`.
- `attempt` — monotonic integer; first attempt is `1`.

The caller (Achilles Step 8.5) constructs the key. `dispatch-review.sh` does not synthesize it.

### Behavior

1. Before spawning an Argus worker, `dispatch-review.sh` reads today's event log for a `review_approved`, `review_flagged`, or `review_blocked` event whose `idempotency_key` matches the supplied key.
2. **Found** → return the prior verdict without spawning. Emit `action_deduped` event with the matching key.
3. **Not found** → spawn Argus, emit the verdict event with the key attached.

### Why today's log only

Argus verdicts are scoped to a task's active session. A verdict from a prior session (different day) for the same task is stale — the diff may have changed. Scoping to today's log prevents stale-verdict reuse across sessions.

## Related

- `message-contract.md` — where the key lives on the envelope.
- `event-emission.md` — reader-side dedupe on the event log.
- `schema-version.md` — content-hash is computed after schema-version normalization.
