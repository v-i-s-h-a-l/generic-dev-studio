# Studio v2 Checkpoint Artifact Contract

Checkpoint artifacts let a host resume a Studio v2 session without storing a
conversation transcript. The contract is intentionally compact and
host-agnostic: resume readers load only `manifest.json` and `context.md` first,
then lazy-load role-owned state, next steps, evidence, and telemetry only when
the resumed session asks for them.

## Runtime Layout

Checkpoints are per-project runtime artifacts under the existing path helper
model:

```text
~/.dev-studio/<project>/.runtime/v2/checkpoints/
  index.json
  sessions/<checkpoint-id>/
    manifest.json
    context.md
    state.json
    next-steps.json
    evidence.json
    telemetry.jsonl
```

The project slug is resolved the same way as other per-project runtime files:
`scripts/lib-paths.sh` resolves `~/.dev-studio/<project>/`; checkpoint writers
append `.runtime/v2/checkpoints`. Checkpoints are private runtime state and are
not a replacement for worker summaries, review verdicts, release packets, or
durable event logs.

## Ownership

The shared checkpoint schema owns storage layout, the index shape, lazy-load
policy, budgets, and telemetry fields. Each role owns the role-specific content
inside `context.md`, `state.json`, `next-steps.json`, and `evidence.json`.
Roles may add fields under their owned content blocks only where the JSON
schema allows role extension.

## Artifact Set

| File | Load policy | Owner | Purpose |
|---|---|---|---|
| `manifest.json` | initial | shared schema | Declares files, budgets, schemas, ownership, and forbidden content policy. |
| `context.md` | initial | producer role | Compact human-readable resume context. Must include goal, current state, next action, and lazy-load hints. |
| `state.json` | lazy | producer role | Structured role state and working tree facts. |
| `next-steps.json` | lazy | producer role | Action list with owner roles and evidence refs. |
| `evidence.json` | lazy | producer role | Pointers and short summaries for command/test/review/diff evidence. |
| `telemetry.jsonl` | append-only | shared schema | One compact event per line for size, drift, usefulness, and v1 tuning signals. |

`index.json` is a shared-schema artifact at the checkpoint root. It contains
only discovery metadata and size/usefulness roll-ups; resume still reads the
session-local `manifest.json` before trusting any role-owned content.

## Content Rules

Checkpoint artifacts MUST NOT store raw transcripts, chat logs, full prompt
history, or large embedded command output. Evidence stores short summaries and
refs to existing artifacts; `inline_excerpt` is capped for orientation only.
Large command output belongs in the original command log, test result, review
artifact, or event stream already owned by that workflow.

Over-budget content MUST NOT be silently truncated. Writers measure the
default-loaded files and emit `checkpoint_budget_warning` telemetry when either
byte or estimated-token budgets cross the manifest warning threshold. A resume
reader may still load the compact default files, but the warning is durable so
budget tuning can happen later.

## Default Resume Load

The default resume load is exactly:

1. `manifest.json`
2. `context.md`

Everything else is lazy. `manifest.json` declares `default_load.files` and
per-artifact `load_policy`; fixture tests assert that the initial set contains
only those two files. Default-loaded files are budgeted and measurable through
`budgets.default_load_max_bytes`,
`budgets.default_load_max_estimated_tokens`, and telemetry `size.*` fields.

## Telemetry

Each `telemetry.jsonl` line validates against
`core/v2/schemas/checkpoint-telemetry-event.schema.json`. Required signal
families are:

- `size`: default-load bytes, total bytes, default-load estimated tokens, total estimated tokens.
- `drift`: whether the checkpoint appears stale against a base and observed ref.
- `usefulness`: resume outcome, loaded files, and short notes.
- `v1_tuning`: compact reason, compaction interval, resume success, and cacheable-prefix estimate when known.

These fields intentionally preserve v1-compatible tuning signals without
embedding v1 transcripts or host-specific session internals.

## Schemas And Fixtures

Schemas live beside other v2 schemas:

- `core/v2/schemas/checkpoint-manifest.schema.json`
- `core/v2/schemas/checkpoint-index.schema.json`
- `core/v2/schemas/checkpoint-state.schema.json`
- `core/v2/schemas/checkpoint-next-steps.schema.json`
- `core/v2/schemas/checkpoint-evidence.schema.json`
- `core/v2/schemas/checkpoint-telemetry-event.schema.json`

The compact default fixture lives at
`core/v2/checkpoints/fixtures/compact-default/`. Validate it with:

```bash
bash scripts/test-fixtures/567-checkpoint-contract/test-checkpoint-contract.sh
```
