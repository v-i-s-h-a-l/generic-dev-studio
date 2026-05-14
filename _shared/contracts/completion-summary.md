---
name: Completion Summary Contract
description: Shared user-facing completion summary shape for manager, worker, reviewer, and debrief paths.
type: contract
---

# Completion Summary Contract

When a role gives the user a task-completion conclusion, the final human note
uses this information architecture:

```text
We fixed/implemented <truthful outcome>.

Impact on user:
Behavior before:
Behavior after:
New behavior:

Operational closure:
PR/merge state:
Local sync state:
Worktree cleanup:
Derived data and stale artifacts:

Safe to end the session.
```

Labels may be adapted to the task type, but the summary must preserve the same
shape:

- Lead with `We fixed ...`, `We implemented ...`, or the closest truthful
  equivalent for review-only, blocked, or no-change work.
- Split user impact into before, after, and new behavior when the task changed
  user-visible behavior. If one field does not apply, say `Not applicable` and
  why in a short phrase.
- State operational closure explicitly: PR or merge status, local sync status,
  worktree cleanup, and derived-data or stale-artifact cleanup.
- End with `Safe to end the session.` only when merge or closure, local sync,
  required cleanup, and required artifact writes actually completed.
- If merge, sync, cleanup, verification, or artifact emission did not happen,
  replace the safe-close line with `Not safe to end the session yet:` followed
  by the remaining blocker or owner.

This contract governs user-facing conclusions only. Typed artifacts such as
worker summaries, debrief YAML, reviewer verdicts, release packets, and event
log entries remain the source of truth for automation.

## Attended Verification Checkpoint

Attended chain runs may pause for explicit human verification (for example,
"test the app and confirm the new behavior"). The pause is a typed halt
record with `reason_id: attended_verification_pending` and
`halt_class: human-needed` (see
`_shared/contracts/chain-halt-record.schema.json`). The record carries the
verification ask, the expected response shape, and a single `next_command`
that routes verified continuation through verified resume.

Required `resumable_state.verification_checkpoint` fields:

- `run_id`, `chain_run_id`, `issue_run_id`, `issue_number` — identity copied
  from the active chain run state.
- `verification_ask` — short human-readable statement of what the user must
  confirm before resume is safe.
- `expected_response_shape` — names the verified-resume route (for example,
  `/dev-studio manager work-chain --resume <run_id> --verified --yes`) so the
  operator never invents free-form chat input.
- `next_safe_action` — what the operator should inspect or do before issuing
  the resume command.
- `recap_ref` — durable pointer (run id plus recap artifact path) the operator
  can read to recover context without chat history.

Halts without a verification checkpoint must not advertise
`--verified --yes`; they continue to use the standard resume command shape.

## Verified Resume Closeout

When an attended chain resumes via the verified route, the finalize path runs
idempotently over the canonical closeout inventory. Each finish step is
classified in the final user-facing summary as **ran**, **already-complete**,
or **skipped with reason**.

Canonical closeout inventory (any item may be `not_applicable` for a given
run shape):

1. Tests, build, and lint evidence persisted to the run report.
2. Worker summary ingested and validated.
3. Commit created on the issue branch with `Closes #<issue>`.
4. Push of the issue branch to origin.
5. PR opened, updated, or already-open against the chain branch.
6. Required review verdict captured (or recorded as not required).
7. Merge into the chain branch (or chain PR opened for the source branch).
8. Source-issue closure handoff to the chain runner.
9. Local `main` synced with `origin/main` after the chain PR merges.
10. Worktree removed and the issue branch deleted locally and on origin.
11. DerivedData and stale artifact janitor pass with retention overrides
    honored.
12. Final run report regenerated and the public recap emitted.

The verified-resume completion summary must include a `Verified resume
closeout:` block under "Operational closure:" with one line per inventory
item: `ran`, `already-complete`, `skipped — <reason>`, or `not_applicable`.
The session is `Safe to end the session.` only when every applicable item is
`ran` or `already-complete` and no `skipped` line lacks an operator-visible
reason.

Unsafe or user-sensitive steps stay gated even on a verified resume:
destructive cleanup honors `STUDIO_KEEP_ARTIFACTS=1` and any retention
override; merges, releases, and external publish actions still respect the
ask-first policy in `CLAUDE.md`.

## Durable Chain Progress Recap

User-facing chain sessions emit a stable progress packet at three boundaries:

- **Before execution.** Chain goal, ordered tasks with dependency edges,
  parallel opportunities (if any), expected human checkpoints, and the next
  command the operator can run.
- **After each task completes.** Previous task, just completed task, what
  changed, verification evidence summary, next task or command, overall
  progress (completed of total), and the current chain direction or goal.
- **On pause, halt, or finish.** What remains, why the run paused or
  finished, and the exact resume command (verified or standard) or recovery
  command.

The recap is derived from durable state: chain manifests, event-log
projections, worker summaries, and halt records. It must not depend on
ephemeral assistant memory, and it must not include private telemetry
payloads, secrets, or raw operator prompts. Telemetry summaries may enrich
the recap but cannot replace the packet above.
