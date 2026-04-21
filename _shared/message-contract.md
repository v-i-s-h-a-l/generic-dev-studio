---
name: Message Contract
description: Canonical envelope every inter-agent message carries (brief, debrief, review verdict, event, snapshot handoff). Transport-agnostic — filesystem today, iMessage/Telegram/HTTP later — envelope does not change.
type: reference
---

# Message Contract (envelope v1)

Every inter-agent message — brief, debrief, review verdict, event, snapshot handoff — carries a common envelope. Consumers validate the envelope, then switch on `payload_schema` to parse the payload. Transport is irrelevant to the envelope: the same shape survives across filesystem artifacts, iMessage DMs, Telegram posts, HTTP calls.

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | `{name, version, min_reader, deprecated_at}` | yes | Per `schema-version.md`. Object form; reader rejects if below `min_reader`. |
| `message_id` | UUIDv7 | yes | Monotonic, timestamped. One per message. |
| `correlation_id` | UUIDv7 | yes | Inherited across a task lifecycle. Brief → debrief → review all carry the same `correlation_id`. |
| `idempotency_key` | string | yes | `<agent>:<mode>:<stable-subject>:<content-hash>`. See `idempotency.md`. |
| `producer` | `{agent, mode, instance_id, version}` | yes | `agent ∈ {chanakya, achilles, argus, luban, chiron}`. `instance_id` disambiguates parallel workers. `version` is the agent git sha. |
| `recipient` | `{agent, version_range?}` \| `"broadcast"` | yes | `version_range` uses SemVer range expressions (`>=2.0.0 <3.0.0`); absent means any version. `"broadcast"` for events. |
| `intent` | enum | yes | `request` / `response` / `event` / `handoff` / `cancel`. |
| `payload_schema` | string | yes | Points at a file under `schemas/` (e.g. `schemas/brief.md`). Used to pick a parser. |
| `payload` | object | yes | Validated against `payload_schema`. Shape is schema-specific. |
| `reply_to` | `message_id`? | no | Present iff `intent == response`. |
| `occurred_at` | RFC3339 UTC | yes | `date -u +%Y-%m-%dT%H:%M:%SZ`. |
| `reads[]` | `[path]` | yes | Declared read surface for this message's action. See `read-write-decls.md`. |
| `writes[]` | `[path]` | yes | Declared write surface. |

`reads` / `writes` are paths after `<project>` expansion — not mode-pack globs. A brief message about to write `plans/briefs/T001.md` declares that exact path, not the glob.

## Example — brief envelope

```json
{
  "schema_version": {"name": "brief", "version": "3.1.0", "min_reader": "3.0.0", "deprecated_at": null},
  "message_id": "018f3c4a-7b6e-7890-abcd-1234567890ab",
  "correlation_id": "018f3c4a-0000-7890-abcd-1234567890ab",
  "idempotency_key": "chanakya:brief:T001:a1b2c3d4",
  "producer": {"agent": "chanakya", "mode": "brief", "instance_id": "session-42", "version": "1a7f12a"},
  "recipient": {"agent": "achilles"},
  "intent": "handoff",
  "payload_schema": "schemas/brief.md",
  "payload": {"task_id": "T001", "…": "…"},
  "occurred_at": "2026-04-22T14:32:01Z",
  "reads":  ["~/.dev-studio/<project>/plans/master-plan.md"],
  "writes": ["~/.dev-studio/<project>/plans/chanakya-tasks/T001-impl.md"]
}
```

## Why this shape

- **One envelope across transports.** Filesystem-today, network-later: same parser.
- **`correlation_id` is load-bearing.** Debugging a blocked task across agents means joining on this field, not on task IDs — task IDs are a payload concept, not every envelope has one.
- **`reads` / `writes` are on the envelope, not the payload.** Agents and linters both need them; duplicating into each payload schema would rot.
- **`payload_schema` as a pointer string.** Keeps envelope compact; consumers that don't know the schema can still route on `intent` + `recipient`.

## What this replaces

- Ad-hoc JSON shapes in debrief + event + review files that drift between agents.
- Event-log entries lacking producer/correlation data (fixed in `event-emission.md`).
- Brief files with inline schema assumptions — now the envelope carries `schema_version`.

## Related

- `schema-version.md` — object-form version record, min-reader semantics.
- `idempotency.md` — how `idempotency_key` is built and enforced.
- `event-emission.md` — event-log subset of this envelope.
- `read-write-decls.md` — mode-pack frontmatter that declares the cross-message surfaces.
