---
name: Chain Run State
schema_version: 1
description: Event-derived projection contract for autonomous studio chain run lifecycle state.
type: contract
---

# Chain Run State

Chain run lifecycle facts are canonical in:

```text
~/.dev-studio/<project>/chain-runs/<run_id>/events.jsonl
```

`state.json` in the same directory is a rebuildable projection. It keeps the
compact shape needed by resume, discovery, monitor sync, reports, and legacy
fixtures, but readers treat it as cacheable state derived from the event stream
plus the declared plan metadata.

## Reducer Rules

The reducer consumes `events.jsonl` in file order. Timestamps are observability
fields; event order is the lifecycle order inside one run log.

Lifecycle precedence is monotonic for externally completed facts:

| Entity | Lower-precedence facts | Higher-precedence facts |
|---|---|---|
| Chain run | `planned`, `running`, `failed` | `completed` from `chain_run_completed` |
| Chain | `pending`, `running`, `failed` | `completed` from `chain_completed` |
| Issue | `pending`, `running`, `failed`, `smoke-passed` | `merged` from `chain_issue_merged` or `chain_completed`; `closed` from `chain_issue_closed` |
| Halt | active halt record | superseded when the run completes after resume |

A completed chain PR (`chain_completed`) implies every issue in that chain is
`completed` and `integrated: true` unless an explicit
`chain_issue_completion_exception` or `chain_issue_finalization_exception`
event targets that issue. This invariant prevents a stale child failure from
surviving after the chain PR and source issue closure prove integration.

When an issue moves to a completed or integrated lifecycle state, current
failure fields such as `failure_reason` and `exit_code` are removed from the
projection. Historical failure evidence remains in `events.jsonl`, worker
summaries, halt records, and reports.

## Resume And Readers

Resume startup validates `state.json` against the reducer projection before
scheduling work. If projection succeeds and differs, the runner writes a
timestamped stale-state backup next to `state.json`, rewrites `state.json` from
the projection, records projection metadata, and emits
`chain_state_projection_repaired`. If the event stream or state file cannot be
projected, the runner writes a typed halt record such as
`chain_state_projection_invalid` rather than scheduling from ambiguous state.

Status readers use the reconciled view:

- `scripts/studio-chain-runner.sh --list`, `--discover`, `--auto`, and
  `--explain-next` read event-derived projections for persisted runs.
- `scripts/chain-monitor-sync.sh` and `scripts/lib-chain-monitor-model.sh` build
  persisted-run rows from the event-derived projection, not raw stale
  `state.json`.

## Locks

Runner state locks include `pid`, `created_at`, `host`, `process`, and
`purpose`. Cleanup treats a same-host live PID with matching process evidence as
live, removes dead or mismatched same-host PID locks, and treats cross-host locks
as live until their age exceeds `STUDIO_CHAIN_LOCK_STALE_S` (default `900`).
Every removed stale state lock emits `chain_stale_lock_removed` with compact
private telemetry.

## Non-Goals

This contract does not introduce SQLite or a new runtime dependency. It also
does not redesign chain manifest persistence; manifest registry semantics live
in `_shared/contracts/chain-manifest-registry.md`.
