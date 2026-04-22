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

## Related

- `message-contract.md` — where the key lives on the envelope.
- `event-emission.md` — reader-side dedupe on the event log.
- `schema-version.md` — content-hash is computed after schema-version normalization.
