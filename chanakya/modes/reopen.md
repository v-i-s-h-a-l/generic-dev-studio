---
name: Chanakya Reopen
description: Reopen a closed task. Validates source state (verified | merged | archived | cancelled), records a reopen reason, appends prior debrief id to reopen_chain, transitions state to reopened, and emits task_reopened so the next brief carries the lineage.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 800
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/<task-id>.yaml                     # post-migration per-task artifact (schema: _shared/schemas/task.md)
  - plans/debriefs/<debrief-id>.yaml               # for prior debrief reference (read-only)
writes:
  - plans/tasks/<task-id>.yaml                     # state → reopened, reopen_reason, reopen_chain append, history append
  - events/<date>.jsonl                            # via scripts/write-event.sh: task_state_changed + task_reopened
---

# Mode: Reopen Task (`/chanakya reopen <task-id> --reason="<text>"`)

Brings a closed task back into the work queue with recorded provenance. The reopen reason is required and prefix-conventional (`qa-rejected:`, `design-rejected:`, `product-rejected:`, `regression:`, `incomplete:`); the prior debrief id is appended to `reopen_chain` so the next brief and Achilles's resulting debrief can stamp the lineage.

State machine: `verified | merged | archived | cancelled → reopened → briefed | archived`. See `_shared/state-machines/task-lifecycle.md` for the authoritative transition table.

## Steps

1. **Resolve the task.** Accept either a UUIDv7 or a legacy task id (`T347`). Resolve to the canonical `plans/tasks/<task-uuid>.yaml` path. If no match, fail with `task-reopen.sh: no task matches <arg>` and exit 2.

2. **Validate the source state.** Read `state` from the task YAML. Refuse with exit 3 unless it is one of `verified`, `merged`, `archived`, `cancelled`. The error names the current state so the user knows whether to wait for verification, cancel, or escalate.

3. **Validate the reason.** `--reason="<text>"` is required, ≤ 280 chars. A free-text reason without a conventional prefix is accepted; the brief mode will surface it verbatim, so callers benefit from prefixing for downstream filtering. Exit 4 on missing or oversize reason.

4. **Apply the transition.** Invoke `scripts/task-reopen.sh <task-id> --reason="<text>"`. The script:
   - Calls `transition_task_state <uuid> reopened chanakya "<reason>"` from `lib-ledger.sh` — YAML state flip, `updated_at` bump, `history` append, and `task_state_changed` event emission.
   - Stamps `reopen_reason` on the task YAML.
   - Appends `links.debrief` (if present) to `reopen_chain`, deduplicated via `unique_by(.)`.
   - Emits `task_reopened` with `{prior_state, reason, prior_debrief_id, chain_depth}` per `_shared/contracts/events.md`.

5. **Report.** Echo `task-reopen.sh: <uuid> <prior_state> -> reopened (chain_depth=N, reason=<text>)`. Surface the next-step hint:
   > "T347 reopened (qa-rejected: blue tint regression on iPad). Run `/chanakya brief T347` to re-brief — the new brief will carry the reopen reason and prior debrief reference."

6. **No re-dispatch from this mode.** Reopen prepares the task for re-briefing; it does not author the brief. The user (or `/chanakya brief-all`) drives the next step. This split keeps the reopen mutation atomic and the brief-author mode the single owner of brief writes.

## Decision: dropping a reopened task

If the user reopens, then decides not to address: invoke `/chanakya cancel <task-id>` (existing path) or, when the task is meant to remain in cold storage, `/chanakya compact` (existing archive flow). Both transitions are legal from `reopened`. No dedicated `--drop` flag — the existing terminal paths are sufficient.

## Idempotency

A second `task-reopen.sh` call on a task already in `reopened` exits 3 (state validator rejects). To re-record a different reason on the same in-flight reopen, the user re-briefs first (`reopened → briefed`) then can reopen again from a future closed state. This avoids silent reason mutation while a reopen is mid-flight.

## Repeated reopens

Each reopen cycle (close → reopen → re-brief → close → reopen) appends one entry to `reopen_chain`. The `unique_by(.)` filter prevents duplicates if the same prior debrief id resurfaces (e.g. an interrupted run); ordinary monotonic growth is preserved because each cycle produces a fresh debrief uuid.

## Verification (synthetic only — never against turnip-ios)

Per `feedback_smoke_test_synthetic_only.md`, smoke runs use a unique throwaway slug or a `HOME`-overridden tmpdir.

1. Mint a synthetic task in state `verified` with one debrief linked.
2. Run `scripts/task-reopen.sh <task-id> --reason="qa-rejected: synthetic test"`.
3. Assert: task YAML state is `reopened`; `reopen_reason` matches; `reopen_chain` length is 1 and contains the prior debrief id; `history[-1].to == "reopened"` with the reason copied to `history[-1].reason`.
4. Assert: today's event log carries one `task_state_changed` (`from: verified, to: reopened`) and one `task_reopened` for the same task uuid, with `chain_depth: 1`.
5. Repeat from a fresh closed state to assert chain growth without dupes.
