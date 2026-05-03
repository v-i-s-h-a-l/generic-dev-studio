# Studio v2 Durable Event-Log Semantics

Status: A0b specification for issue #444. This document is the v2 target contract for A4 implementation and A0.5 SPEC composition; it does not change the v1 runtime by itself.

## Relationship to Existing Contracts

Studio v1 already has a working event substrate:

- `_shared/contracts/events.md` defines the current JSONL schema, one-line append contract, event catalog, and offset-marker consumer pattern.
- `_shared/contracts/event-emission.md` defines producer tagging, idempotency key requirements, catalog discipline, and reader-side dedupe.
- `_shared/contracts/idempotency.md` defines stable key construction, retry behavior, and the v1 "no event-log write locks" stance.

Studio v2 inherits the proven parts unchanged unless A0.5 SPEC explicitly supersedes them: day-partitioned JSONL, one event per line, bounded payloads, append-only writes, producer identity, idempotency keys for writable actions, and reader-side dedupe. This document tightens the durable semantics for ordering, dedupe, replay, locks, and backpressure so A4 can implement subscribers without inventing a parallel bus.

The v2 event log is the durable fact stream. Derived snapshots, dashboards, indexes, push queues, and subscriber checkpoints are rebuildable views.

## Scope

In scope:

- Event append semantics.
- Subscriber replay and checkpoints.
- Logical duplicate handling.
- Lock boundaries around the log and subscriber state.
- Backpressure behavior when consumers fall behind or payloads exceed the durable-log envelope.

Out of scope:

- Final event catalog vocabulary. A0.5 SPEC composes the catalog; A4 implements it.
- Host capability schema. A0a owns host capability inputs.
- Auth and permission failures. A0c owns auth semantics.
- Role handoff schemas. A0d owns role contracts.
- Runtime code for subscribers. A4 owns implementation.

## Storage Model

The canonical log remains per-project and day-partitioned:

```text
<project-runtime>/events/<YYYY-MM-DD>.jsonl
```

Each line is one complete JSON object. Producers append; they never rewrite, truncate, sort, rotate, or delete event shards. Retention and archival can move cold shards only after A0.5 defines a recovery procedure that preserves replay from an explicit checkpoint.

Large payloads do not belong in the log. Producers write a durable artifact first, then append an event containing a stable artifact reference and bounded summary.

## Ordering Semantics

### v1 Today

v1 consumers mostly treat file order as the processing order for one day and use timestamps for display. Day-boundary handling is described by the offset marker in `_shared/contracts/events.md`.

### v2 Target

The only authoritative total order inside one shard is byte order in the JSONL file. Timestamps are metadata and must not be used to break ordering ties. Across shards, the ordering key is:

```text
(shard_date, byte_offset)
```

where `shard_date` comes from the filename and `byte_offset` is the start byte of the event line.

Per-subject workflows that need stronger ordering use event data, not central log coordination. A producer that emits multiple events for the same logical subject includes a stable subject key and a producer-owned ordinal or attempt field. Consumers use that subject-level field to detect gaps or stale retries; they do not infer causality from wall-clock timestamps.

### Delta

v2 makes byte offset a first-class replay coordinate and demotes `ts` to observability. This preserves append-only simplicity while making recovery deterministic under clock skew and parallel producers.

## Dedupe Semantics

### v1 Today

v1 uses `idempotency_key` for writable actions and `scripts/read-events.sh` dedupes first occurrence by `(producer.agent, idempotency_key)` when requested.

### v2 Target

Event append is at-least-once. Logical processing is exactly-once per subscriber checkpoint when the event carries an idempotency key.

Consumer dedupe key:

```text
(producer.agent, idempotency_key)
```

Events without `idempotency_key` are non-dedupable observations and pass through unchanged. Writable actions must carry an idempotency key; missing keys on writable event types are validation failures under A0.6.

When duplicate keyed events appear, consumers keep the first event by `(shard_date, byte_offset)` and record later duplicates as ignored. Duplicate detection must not delete or rewrite log lines.

### Delta

v2 names the processing guarantee explicitly: at-least-once durable append, first-seen logical dedupe for keyed actions, no exactly-once write claim.

## Replay Semantics

### v1 Today

Chanakya stores an offset marker for today's file, resets on day changes, and reads from byte offset to EOF.

### v2 Target

Every durable subscriber owns a checkpoint under project runtime state. A checkpoint records:

```yaml
subscriber: <name>
shard: <YYYY-MM-DD.jsonl>
byte_offset: <next-byte-to-read>
last_event_id: <optional durable event id when the schema carries one>
updated_at: <UTC timestamp>
```

Replay starts at the checkpoint's `byte_offset` in `shard`, processes complete lines in byte order, then atomically replaces the checkpoint after side effects for that event are durable. This means a crash can replay the last processed event; dedupe and idempotent subscriber writes must make that safe.

If the checkpoint references a missing shard, an offset past EOF, or a partial final line, the subscriber fails loud with a recovery reason and does not silently skip. Recovery policy can rewind to the shard start only when the subscriber records the rewind reason in its checkpoint history or emits a recovery event.

Malformed event lines are not ignored. A subscriber writes a dead-letter artifact containing shard, byte offset, parse error, and bounded line excerpt, then continues only if its mode classifies malformed events as non-blocking. A0.6 decides which subscribers must block on malformed input.

### Delta

v2 generalizes the single Chanakya offset marker into per-subscriber checkpoints and makes replay failure modes explicit.

## Lock Semantics

### v1 Today

The idempotency contract says "No locks" for event-log writes; single-writer-per-subject is enforced upstream. Separate systems still use locks for unrelated resources, such as merge safety and build slots.

### v2 Target

The event log itself has no central write lock. Producers rely on bounded single-line append and never acquire a repo-wide or project-wide event-log mutex before appending.

Allowed locks:

- Resource locks outside the log, such as merge locks, build-slot locks, chain-run locks, and subscriber-local checkpoint locks.
- Atomic file replacement for checkpoints and derived artifacts.
- Per-subject state-machine ownership before emitting events about that subject.

Forbidden locks:

- A global event-log write lock.
- A subscriber lock that blocks producers from appending.
- A lock whose loss causes silent event drop.

Lock events are observations about resource state, not the mechanism that makes the event log consistent. If a lock controls work that emits events, the event must include enough context for a subscriber to understand the lock outcome without reading the lock file.

### Delta

v2 separates event-log durability from resource coordination. The log remains lock-free for append; locks belong to producers, resources, or subscriber checkpoints.

## Backpressure Semantics

### v1 Today

v1 has queue depth and lock wait telemetry for build dispatch, but no general event-log backpressure contract.

### v2 Target

Producers append bounded events and continue unless the append itself fails. Subscribers absorb lag through checkpoints; they do not block producers.

Backpressure is surfaced through lag signals, not hidden sleeps:

- A subscriber tracks lag by newest shard/offset seen versus its checkpoint.
- When lag exceeds the subscriber's threshold, it records a lag event or status artifact with subscriber name, lag duration, pending bytes, and the oldest unprocessed shard.
- Non-critical subscribers degrade by skipping derived refresh work, never by dropping source events.
- Critical subscribers fail loud when they cannot catch up within their defined recovery budget.

Payload backpressure is handled before append. If an event would exceed the single-line size budget, the producer writes a durable artifact and appends a small reference event. If the artifact write fails, the producer fails the user-visible action rather than appending an incomplete event.

Disk backpressure is a hard failure. A producer that cannot append because the project runtime is unavailable, full, or permission-denied must report the failure to its caller. Best-effort telemetry may be dropped only when the caller explicitly marks it non-critical; task, review, release, and chain lifecycle events are critical.

### Delta

v2 introduces subscriber lag as a first-class operational state and prevents lag from turning into source-event loss.

## Validation Invariants for A0.6

A0.6 enforcement should validate these invariants before A4 depends on subscribers:

- Each event line is valid JSON and one physical line.
- Each event line stays within the configured atomic append budget.
- Required envelope fields are present: timestamp, producer identity, event name, subject/task, and data object.
- Event names are registered before use.
- Writable event types carry `idempotency_key`.
- Subscriber checkpoints are atomically written and point to valid shard coordinates.
- Malformed lines and checkpoint recovery are surfaced as explicit artifacts or events.
- Derived views can be rebuilt from log shards plus their own schemas.

## A0.5 Composition Notes

A0.5 SPEC should decide the final field names and schema versions for:

- durable event id, if retained in addition to `(shard_date, byte_offset)`;
- subscriber checkpoint artifacts;
- lag status artifacts and lag event names;
- dead-letter artifacts;
- critical versus non-critical event classes.

Any field that downstream agents gate on is a behavior contract, not prose. Additions or enum changes to those fields are ask-tier review changes.

## Carryover

- A4 implements subscribers, checkpoints, dead-letter handling, and lag surfacing.
- A0.6 wires schema and invariant validation into pre-commit and CI.
- Test-harness discovery for `tests/contracts/` remains a follow-up unless A0.5 chooses a different contract-test directory.
- Pre-existing warnings from the prior phase review (`W_ARGUS_SECRET_SCOPE`, `W_MISSING_SCHEMA_REF`) remain outside this leaf.
