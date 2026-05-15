---
name: Composite Chain State
schema_version: 1
description: Durable state and manifest contract for a sequential composite supervisor over existing child-chain primitives.
type: contract
---

# Composite Chain State

Composite chain state is private runtime state for a supervisor that sequences
existing child chains. It does not replace `manager plan-chain`,
`manager work-chain`, or `studio-chain-runner`; it records which child is active,
which artifacts prove the child boundary, and which command can continue or
resume the composite run.

Formal validation lives in
`_shared/contracts/composite-chain-state.schema.json`.

## Scope

The composite layer owns:

- ordered child source discovery from an explicit manifest or explicit parent
  issue references;
- durable composite state;
- child-boundary sequencing;
- compact status and recap output;
- halt/resume delegation.

Each child still uses the existing lifecycle:

1. `manager plan-chain` for the active child only.
2. Phase review and issue or manifest creation.
3. `manager work-chain` / `studio-chain-runner` execution.
4. PR review, merge or finish policy, issue update, and artifacts.
5. Durable child completion before the next child is planned.

Natural-language extraction from parent issue text is a non-goal for the MVP.
The supervisor consumes explicit child issue refs or an explicit manifest.

## Composite Manifest

The MVP manifest shape is:

```yaml
kind: composite-chain
schema_version: 1
name: benchmark-insights-roadmap
mode: sequential
children:
  - id: ui-ia-redesign
    source_type: issue
    issue: 123
  - id: similar-scenario-insight
    source_type: issue
    issue: 124
```

`children[].id` is the stable child identity. It is reused in state,
idempotency keys, status output, event payloads, and resume commands. IDs are
slugs, not issue titles, so they stay stable when issue titles change.

`source_type: issue` requires `issue`. `source_type: manifest` requires
`manifest_path`. A later schema can add registry-backed refs without changing
the issue-child shape.

## State Shape

The state artifact uses:

- `schema_version: 1`;
- `kind: composite-chain-state`;
- `composite_run_id`;
- `source_ref`, pointing at either a parent issue URL or a manifest path;
- optional embedded `manifest` snapshot;
- `state`;
- ordered `children[]`;
- `current_child_index` and `current_child_id`;
- `active_halt_ref`;
- `blocked_reason`;
- `next_command`;
- `idempotency_keys`;
- timestamps.

Each child carries:

- `id` and zero-based `ordinal`;
- `source`;
- `status`;
- `refs`;
- optional `blocked_reason`;
- child-scoped `idempotency_keys`;
- timestamps.

Child `refs` include:

- `planner_artifact`;
- `review_artifact`;
- `work_chain_manifest`;
- `child_run_id`;
- `issue_url`;
- `pr_url`;
- `completion_summary`.

Private artifact paths stay in runtime state. Public comments mention only issue
numbers, PR URLs, run IDs, and abstract reason IDs.

## State Machine

Composite run states are:

| State | Meaning |
|---|---|
| `initialized` | State exists but no child is ready to plan yet. |
| `child_ready` | The next child is known and ready for `manager plan-chain`. |
| `planning_child` | The active child is being planned or reviewed. |
| `child_planned` | The active child has a reviewed work-chain manifest. |
| `running_child` | The active child is executing through `manager work-chain` / `studio-chain-runner`. |
| `child_completed` | The active child is durably complete and the supervisor can advance. |
| `halted` | The composite supervisor has delegated to a halt record or child resume path. |
| `completed` | Every non-skipped child has reached a terminal state. |

Per-child statuses are:

```text
pending | planning | planned | running | completed | halted | skipped
```

## Invariants

The schema enforces that at most one child has `status: planning` or
`status: running` at the same time.

The supervisor must also enforce these ordering invariants:

- child IDs are unique within one composite run;
- later children remain `pending` until every earlier non-skipped child is
  `completed`;
- `current_child_index` and `current_child_id` point at the same child when a
  child is active;
- a child can move to `planned` only after a planner artifact and review artifact
  exist;
- a child can move to `running` only after a work-chain manifest exists;
- a child can move to `completed` only after its child run completion summary is
  durable;
- `next_command` is present whenever the state is resumable.

JSON Schema cannot fully express property-level uniqueness, index-relative
ordering, or cross-field ID equality without making the state format brittle.
Runners validate those invariants when writing or resuming state.

## Idempotency

State and child records carry scoped `idempotency_keys` so resumes can retry
boundary actions without duplicating comments, child manifests, or events.
Recommended keys:

| Scope | Key |
|---|---|
| Composite run | `state_update` |
| Child planning | `child:<child-id>:planning` |
| Child plan review | `child:<child-id>:plan-review` |
| Child work-chain run | `child:<child-id>:run` |
| Child completion recap | `child:<child-id>:completion-recap` |
| Composite completion | `composite:completion` |

Keys are logical strings. Writers may add additional keys for concrete mutation
surfaces.

## Events

Composite event names are cataloged in `_shared/contracts/events.md`. Event
payloads stay compact and public-safe:

- issue numbers;
- PR URLs;
- run IDs;
- child IDs;
- abstract reason IDs.

Private local paths remain in this state artifact or other runtime artifacts.

## Non-Goals

This contract does not implement `manager-composite-chain.sh`, route manager
commands, execute child chains, or plan children from free-form parent issue
text.
