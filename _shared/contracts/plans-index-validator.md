---
name: Plans Index Validator
description: Validator contract for plans/index.yaml and artifact cross-references. Enforces bidirectional consistency (links in artifacts match index entries match artifacts). Run by scripts/rebuild-index.sh and by pre-commit.
type: reference
---

# Plans Index Validator

`plans/index.yaml` is the authoritative relational join over every artifact under `plans/`. Individual artifacts carry back-references in their `links:` block. The validator enforces the invariants that tie these two shapes together so consumers can trust either one in isolation.

Implementation: `scripts/rebuild-index.sh` emits the index; `scripts/validate-plans-index.sh` runs the rules below. Pre-commit invokes both when any artifact under `plans/` is staged (not yet wired — lands in Commit D).

## Invariants

### 1. Every `links:` back-reference resolves to an index entry

For every artifact A with a non-null reference to artifact B (via `A.links.<kind>` or `A.<kind>`, e.g. `task.links.brief`, `review.subject.id`, `release.tasks[]`):

- `plans/index.yaml` MUST contain an entry for B under its kind.
- Violation tier: **block**. Emit `E_INDEX_MISSING_ENTRY:<artifact>:<reference>` — rebuild the index or confirm the artifact exists.

### 2. Every index entry points at a real artifact file

For every entry in `plans/index.yaml` (e.g. `tasks[].id`, `briefs[].id`):

- `plans/<kind>s/<id>.yaml` MUST exist.
- Violation tier: **block**. Emit `E_INDEX_DANGLING:<kind>:<id>` — the artifact was deleted without regenerating the index.

### 3. Bidirectional link consistency

For every directed reference in an artifact, the reverse reference MUST exist in the target:

| Forward reference | Reverse reference |
|---|---|
| `task.links.brief = X` | `brief.task_id = task.id AND brief.id = X` |
| `task.links.debrief = X` | `debrief.task_id = task.id AND debrief.id = X` |
| `task.links.reviews[] contains X` | `review.id = X AND review.subject = {kind: task, id: task.id}` |
| `task.links.release = X` | `release.id = X AND release.tasks[] contains task.id` |
| `task.links.feedback[] contains X` | `feedback.id = X AND feedback.linked_tasks[] contains task.id` |
| `brief.task_id = X` | `task.id = X AND task.links.brief = brief.id` (for the current brief) |
| `debrief.task_id = X` | `task.id = X AND task.links.debrief = debrief.id` (for the latest debrief) |
| `debrief.brief_id = X` | `brief.id = X AND brief.task_id = debrief.task_id` |
| `review.subject = {kind: task, id: X}` | `task.id = X AND task.links.reviews[] contains review.id` |
| `review.subject = {kind: round, id: X}` | `round.id = X AND round.reviews[] contains review.id` |
| `review.subject = {kind: release, id: X}` | `release.id = X AND release.reviews[] contains review.id` |
| `round.tasks[] contains X` | `task.id = X` (no task-side back-ref required; rounds are aggregates) |
| `release.tasks[] contains X` | `task.id = X AND task.links.release = release.id` |
| `feedback.linked_tasks[] contains X` | `task.id = X AND task.links.feedback[] contains feedback.id` |
| `feedback.linked_crashes[] contains X` | `crash.id = X AND crash.linked_feedback[] contains feedback.id` |
| `crash.linked_feedback[] contains X` | `feedback.id = X AND feedback.linked_crashes[] contains crash.id` |

- Violation tier: **block**. Emit `E_LINK_ASYMMETRY:<from-artifact>:<to-artifact>:<kind>` — writer that created the forward reference failed to emit the reverse; re-run the writer or patch manually.

**Historical note on one-to-many:** A task may have many debriefs across rework cycles. `task.links.debrief` names only the **latest** debrief (per `debrief.completed_at`); older debriefs are retained as files but not back-referenced from the task. The validator checks only the current pointer — it does not flag older debriefs for missing back-refs.

Likewise `task.links.brief` names the **current** brief; superseded briefs exist as files but do not appear in `task.links`.

### 4. No orphans — warn

An artifact with no inbound reference (not cited by any other artifact's links) is surfaced as a warning:

- Violation tier: **warn**. Emit `W_ARTIFACT_ORPHAN:<kind>:<id>` — artifact exists but nothing references it. May be intentional (e.g. a draft brief) or a bug (writer forgot to link).

Orphan detection runs against the index (faster than re-scanning files).

### 5. No dangling references — block

A forward reference to an artifact that does not exist in the index (`E_INDEX_MISSING_ENTRY`) is already covered by rule 1. This rule extends it: if the index is stale (missing an entry that an artifact file exists for), that is also a block:

- Violation tier: **block**. Emit `E_INDEX_STALE:<kind>:<id>` — regenerate the index. Occurs when a file lands without the generator running.

### 6. Schema-version compatibility

For every artifact:

- `schema_version.name` MUST equal the filename's implied type (e.g. `plans/tasks/<id>.yaml` ⇒ `schema_version.name == "task"`).
- `schema_version.version` MUST be `>= min_reader` known to this validator. The validator carries a table of known-versions per type and rejects unknown or below-min-reader values.
- Violation tier: **block**. Emit `E_SCHEMA_VERSION_MISMATCH:<file>:<reason>`.

### 7. Deprecation awareness

If an artifact's `schema_version.deprecated_at` is non-null and in the past:

- Violation tier: **block**. Emit `E_SCHEMA_DEPRECATED:<file>:<name>@<version>` — rewrite this artifact against the current schema version.

If `deprecated_at` is in the future:

- Violation tier: **warn**. Emit `W_SCHEMA_DEPRECATION_PENDING:<file>:<name>@<version>` with the deprecation date.

### 8. UUID uniqueness

Every `id` in `plans/index.yaml` and in every artifact file MUST be unique across the entire `plans/` tree. Collisions are a hard bug:

- Violation tier: **block**. Emit `E_UUID_COLLISION:<id>:<file1>,<file2>`.

## Validator output

Machine-readable form — one finding per line:

```
<CODE>:<artifact-path>[:<detail>] | <fix-hint>
```

Human-readable summary at end — pass/fail, finding counts per tier:

```
plans-index-validator: 2 block, 1 warn
```

Exit code 0 on pass (no block-tier findings), 1 on any block. Warnings never fail the validator.

## Integration

- `scripts/rebuild-index.sh` runs the validator after emitting the index. A block-tier finding causes the generator to exit non-zero and leave the old `index.yaml` in place (no partial update).
- Pre-commit hook runs `scripts/validate-plans-index.sh` when any staged file is under `plans/`. Block-tier findings fail the commit.
- Migration script (`scripts/migrate-ledger.sh`) runs the validator as part of the diff-verify phase — any violation after cutover means the transform or index generator has a bug.

## Performance notes

For a project with 141 tasks + artifacts across 8 kinds, a single-pass validator walks < 1000 files and completes in under 2 seconds on the pilot machine. If the project scales past ~500 artifacts per kind, move to incremental validation (hash the index; re-validate only on mismatch). Not required for 2.6.

## Related

- `schemas/task.md` / `schemas/brief.md` / `schemas/debrief.md` / `schemas/review.md` / `schemas/round.md` / `schemas/release.md` / `schemas/feedback.md` / `schemas/crash.md` — artifact schemas carrying the `links:` blocks this validator checks.
- `contracts/schema-version.md` — schema-version object semantics.
- `contracts/events.md` — `index_regenerated`, `index_validation_failed` (additive catalog entries landing with Commit D).
- `scripts/rebuild-index.sh` / `scripts/validate-plans-index.sh` — implementation (Commit D).
