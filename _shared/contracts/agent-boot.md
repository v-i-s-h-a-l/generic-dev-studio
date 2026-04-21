---
name: Agent Boot Contract
description: Every agent session emits an agent_boot event at first write, carrying a minimal payload — agent, git_sha, skill_version. Enables session-level traceability without per-session payload bloat.
type: reference
---

# Agent Boot Contract

Every agent session (Chanakya, Achilles, Argus) emits one `agent_boot` event at first write, then never again for the rest of the session. The payload is deliberately minimal — three fields that cover the common debug need ("which agent, running what code, on what studio version") without taxing every session to keep richer fields current.

Per Q3 (right-sized 2026-04-20), additional fields (`schema_versions`, `loaded_mode_packs`, `active_snapshots`, `token_budget`) land only when a specific debugging session demonstrates they would have saved time. See `PHASE-2-6-PLAN.md` §8.1 for rationale.

## Payload shape

```yaml
schema_version:
  name: agent-boot
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
agent: achilles                    # chanakya | achilles | argus
git_sha: a1b2c3d                   # short-sha of the studio repo at session start
skill_version: 1.2.0               # SemVer from SKILL.md frontmatter
```

Three fields. Nothing else. When a future debugging session proves it needs more, add one field at a time — reject blanket additions.

## When emitted

At first write of an agent session — defined as the first action that appends to the event log or writes an artifact. The emitter checks for a session-local sentinel (`~/.dev-studio/<project>/.runtime/agent-boot-sent-<session-id>`) and skips re-emission if present.

Sessions that perform only reads never emit `agent_boot` — the event is tied to writes, not session existence. Read-only sessions are invisible to the ledger by design.

## Event shape (in the event log)

```json
{
  "ts": "2026-04-22T14:32:01Z",
  "agent": "achilles",
  "event": "agent_boot",
  "task": "T001",
  "data": {
    "schema_version": {"name": "agent-boot", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
    "agent": "achilles",
    "git_sha": "a1b2c3d",
    "skill_version": "1.2.0"
  },
  "producer": {"agent": "achilles", "mode": "task", "instance_id": "<session-id>"},
  "idempotency_key": "achilles:agent-boot:<session-id>"
}
```

Idempotency key is `<agent>:agent-boot:<session-id>` — dedupes re-fires within a session if the sentinel lookup fails.

## Emitter helper

`scripts/emit-agent-boot.sh` writes the event + touches the sentinel:

```bash
scripts/emit-agent-boot.sh <agent> <session-id> <skill-version>
```

- `<agent>` — one of `chanakya`, `achilles`, `argus`.
- `<session-id>` — caller-chosen identifier stable for the session (e.g. a mode's PID + wall-clock, or a task-id for per-task sessions).
- `<skill-version>` — read from the SKILL.md frontmatter `version:` field.

The script resolves `git_sha` by running `git rev-parse --short HEAD` in the studio repo (path resolved via `$ACHILLES_STUDIO_REPO` env var or the git toplevel ancestor of the calling script). The event lands in the project event log via `lib-paths.sh`'s `append_event` helper.

Idempotency is enforced by sentinel: if `~/.dev-studio/<project>/.runtime/agent-boot-sent-<session-id>` exists, the helper no-ops.

## Reader validation

Any consumer of artifacts validates `schema_version` per `contracts/schema-version.md`:

1. Artifact's `schema_version` is known to this reader.
2. Reader's version ≥ artifact's `min_reader`.
3. Fail loudly on mismatch — emit `schema_read_rejected`, refuse to process. Never silently degrade.

`scripts/validate-schema.sh` is the shared validation primitive (ships alongside this contract):

```bash
scripts/validate-schema.sh <artifact-path>     # exits 0 if schema is accepted
scripts/validate-schema.sh <artifact-path> --reader-table=<path>
                                                # exits 1 if reader < min_reader
```

Default reader-version table lives at `_shared/schemas/reader-versions.json`. Each entry pins the reader's max-known-version + min-acceptable-version per schema name.

## Mismatch handling

Two buckets per `PHASE-2-6-PLAN.md` §8.3:

- **Reader too old** (`reader_version < artifact.min_reader`) — block. User upgrades studio.
- **Reader too new** (`reader_version > artifact.version`) — allowed if `artifact.deprecated_at` is null. Emit `schema_version_gap` (warn). If `deprecated_at` is in the past, block.

`scripts/validate-schema.sh` implements both buckets, emits the appropriate event, exits 0 for warn and 1 for block.

## Why minimal

A richer payload (schemas loaded, budgets, mode packs) is tempting but carries a discipline tax — every field must be kept current, or the data is misleading. The three fields here are both load-bearing (answers real debug questions) and cheap to emit correctly. Additive shape: expanding the payload later is a minor-version bump.

## Related

- `contracts/schema-version.md` — the envelope semantics this event's `schema_version` field uses.
- `contracts/events.md` — `agent_boot`, `schema_version_gap`, `schema_read_rejected` catalog entries (additive in 2.6).
- `scripts/emit-agent-boot.sh` — reference implementation.
- `scripts/validate-schema.sh` — reader-side validator.
- `patterns/chanakya-principles.md` — Chanakya Step 0 invokes the emit helper.
