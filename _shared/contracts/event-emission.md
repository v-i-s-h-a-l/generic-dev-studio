---
name: Event Emission Contract
description: Rules every event producer follows — producer tagging, idempotency key on every event, catalog lookup, atomic append. Extracted from chanakya-principles.md so every agent can reference it.
type: reference
---

# Event Emission Contract

Every agent — Chanakya, Achilles, Argus, and anything later — emits events to the shared log. This file is the authoritative emitter-side contract. The event schema + catalog live in `events.md`; consumer-side offset handling lives there too.

## Rules

1. **Every event carries `producer`.** The envelope has `{agent, mode, instance_id}`. `instance_id` distinguishes parallel workers on the same agent. Without `producer`, cross-agent debugging degenerates into guessing.
2. **Every event carries `idempotency_key` when the emitting action is writable.** Construction per `idempotency.md`. Session-lifecycle events (`agent_session_completed`, `snapshot_generated`) do not need keys — they do not represent a dedupable write.
3. **Reader-side dedupe on `(producer.agent, idempotency_key)`.** Best-effort: duplicates are rare at single-user scale. Use `scripts/read-events.sh` (first-occurrence wins); events without `idempotency_key` — session lifecycle (`agent_session_completed`) and snapshot events — pass through unchanged.
4. **≤ 4096 bytes per line.** POSIX `O_APPEND` is atomic only under `PIPE_BUF`. Long payloads truncate strings at 200 chars or link to artifact files (`review_file`, `debrief_path`).
5. **Append pattern is `printf >>`.** Not `echo`, not buffered. See `events.md` for the pattern.
6. **Emit before sitting idle.** `agent_session_completed` is mandatory at the end of every agent session (any mode). Duration alone is still useful if token counts are unavailable.
7. **Use the catalog.** New event types land in `events.md` first, then producers emit them. Drive-by events that are not in the catalog are dropped by consumers.

## Envelope for a single event

```json
{
  "ts": "2026-04-22T14:32:01Z",
  "agent": "achilles",
  "event": "task_completed",
  "task": "T001",
  "data": {},
  "producer": {"agent": "achilles", "mode": "task", "instance_id": "worker-2"},
  "idempotency_key": "achilles:task:T001:e5f6a7b8"
}
```

Fields `ts` / `agent` / `event` / `task` / `data` are the pre-existing `events.md` shape. `producer` and `idempotency_key` are additive (minor version bump). `agent` at the top level remains for reader-side filter convenience; `producer.agent` is the authoritative emitter identity.

## What this replaces

- Implicit producer identity (previously inferred from `agent` field — fine until two Achilles workers emitted identical events and reader couldn't tell them apart).
- Silent duplicates — prior contract was "best-effort, do not worry"; this one says "best-effort at write time, dedupable at read time".

## Non-goals

- Exactly-once delivery semantics. The reader dedupes; the writer is best-effort.
- Write-time locking. Locks cost more than double-processing at this scale.

## Enum faithfulness

Where an event's `data` field carries an outcome enum (e.g. `brief_completed.gate`), the emitter computes the specific value from the strongest available signal — never collapses distinct outcomes into a coarser label for convenience. If the contract defines four values, the emitter picks one of the four. If back-compat requires a coarser alias for legacy consumers, emit it as a sibling field (e.g. `gate_legacy`), not as a degraded `gate`. See `events.md` → `brief_completed.gate` taxonomy for the worked example.

## Related

- `events.md` — schema, atomicity, offset, event catalog.
- `idempotency.md` — key construction.
- `message-contract.md` — event is a specialization of the envelope with `intent: event`.
- `chanakya-principles.md` — no longer restates this; references here instead.
