---
name: Worker Report Contract
description: Four-state enum workers emit on every debrief so the manager routes deterministically instead of parsing prose. Extends `schemas/debrief.md` with an optional `report_state` field (default inferred back-compat).
type: contract
---

# Worker Report Contract (`report_state`)

Every debrief a worker writes carries a `report_state` — the worker's structured answer to "what just happened and what should the manager do next?". Replaces prose-parsing inside the inbox sweep.

## The four states

| State | Meaning | Chanakya routing |
|---|---|---|
| `done` | Task complete, all verification green, nothing outstanding. | Mark task `done`; no follow-up. Normal close. |
| `done_with_concerns` | Task merged, but with caveats the user should see — build debt, skipped tests, deferred edge cases, reviewer flags addressed but left residue. | Mark task `done`; surface concerns in manager status; mint follow-ups from `follow_ups:` per normal. |
| `blocked` | The worker could not merge. Requires user input, external dependency, or escalation. No merge occurred; no commits on base. | Mark task `blocked`; push to user; do not re-dispatch automatically. |
| `needs_context` | The brief was incomplete — a reference, spec, or decision the worker needed was missing. Re-dispatch after the manager regenerates the brief with the missing info. | Mark task `needs_brief_rework`; the manager regenerates the brief filling the gap; automatic re-dispatch once brief state returns to `ready`. |

## Review finding response protocol

When a worker receives reviewer findings, it records a `review_responses` array in the debrief or worker summary before applying reviewer-requested changes. Each entry consumes the review finding's structured metadata and records one response state:

| Response state | Meaning |
|---|---|
| `accepted_and_fixed` | The finding is valid and the requested fix landed directly. |
| `accepted_with_modified_fix` | The finding is valid, but the worker changed the implementation shape to preserve the task plan or architecture contract. |
| `rejected_with_rationale` | The worker did not apply the finding and records why. |
| `needs_manager_planner_decision` | The finding may require scope, architecture, or acceptance-criteria arbitration. |
| `deferred_follow_up` | The finding is real but belongs in a follow-up rather than the current bounded task. |

Each response includes:

```yaml
review_responses:
  - finding_id: R6_docs_sync
    response_state: accepted_with_modified_fix
    self_check: "Does not change the command surface; docs-only clarification preserves the plan."
    rationale: "Kept README untouched because the touched surface is an internal contract, not a user-visible command."
    implemented_change: "Updated _shared/schemas/review.md instead."
    review_metadata:
      severity: medium
      likelihood: likely
      impact: medium
      change_risk: medium
      confidence: high
      basis: task-context
      recommended_action: accepted_with_modified_fix
```

The `self_check` is mandatory. It answers: "could this requested fix break a broader contract or undo the accepted plan?" High `change_risk` with `likelihood: uncertain` must route to `needs_manager_planner_decision` or `deferred_follow_up`; do not blindly patch.

## Review loop budget

Workers track review/fix cycles with:

```yaml
review_loop:
  attempt: 2
  budget: 2
  escalation_required: false
```

Budget is two fix cycles per bounded task. A third review attempt, conflicting findings, or repeated high-risk uncertain findings sets `escalation_required: true` with `escalation_reason` and routes to manager/planner arbitration. This preserves blockers for real correctness, contract, and regression risks while preventing local review churn from rewriting the original plan.

## Same-host self-review gate

Workers run same-host self-review after implementation and before final verification. The review is a reasoning gate, not a second test pass: it checks missed edge cases, possible bugs, regressions, scope drift, and test adequacy. Material findings are fixed or recorded as blocked before final verification starts, so the final test/build/lint evidence is captured once after the reviewed fixes.

Worker summaries and debriefs distinguish the gate from external reviewer responses:

```yaml
self_review_performed: true
self_review_findings:
  - id: SR1
    focus: edge_case
    finding: "Empty input path was not covered by the first implementation."
    severity: material
    disposition: fixed
self_review_fixes:
  - finding_id: SR1
    action: fixed
    summary: "Added the empty-input guard before final verification."
final_verification_evidence:
  - command: "scripts/test-fixtures/605-self-review-gate/test-self-review-gate.sh"
    outcome: pass
    timestamp: 2026-05-05T01:30:00Z
    after_self_review_fixes: true
```

External reviewers inspect these fields before deciding whether to rerun tests. Missing same-host self-review is a workflow defect; reviewers record it as a warn or block depending on the review target and risk.

## Refactoring pressure protocol

Worker self-review records refactoring pressure without turning every task into a cleanup task:

```yaml
refactoring_pressure:
  needed_now:
    - kind: localized_cleanup
      reason: "Duplicated parsing would make the touched change unsafe to maintain."
      affected_area: "FilterPresetParser"
      risk: low
      implemented_change: "Extracted parsePresetName(_:) before adding the new branch."
  deferred_follow_ups:
    - kind: awkward_boundary
      reason: "Repeated edits now cross the editor/export boundary."
      affected_area: "ExportCoordinator and EditorSessionStore"
      risk: medium
      suggested_timing: "Plan after the current release branch closes."
      follow_up_ref: "#123"
```

`needed_now[]` is only for refactors required for correctness, maintainability of the touched change, or safe completion of the bounded task. `deferred_follow_ups[]` is for code bloat, duplication, SOLID/design pressure, awkward boundaries, or localized cleanup that is real but not required now. Deferred items must also be copied into `follow_ups[]` with `category: refactoring-follow-up` when the manager should mint explicit work.

## Schema

`report_state` is an optional field on `schemas/debrief.md` (debrief@2.0.2, non-breaking add). When absent, readers infer back-compat:

- `argus_review.status: approved` + no debt flags → `done`
- `argus_review.status: approved` + any `debt.*: true` or `tests.skipped_because` non-null → `done_with_concerns`
- `argus_review.status: blocked` → `blocked`
- No merge_sha AND `known_issues` mentions brief/missing-context → `needs_context`
- Otherwise → `done_with_concerns` (conservative default — surfaces to user rather than silently closing)

New debriefs (post-2026-04-23) SHOULD set `report_state` explicitly. Enforcement at `scripts/lib-ledger.sh::write_debrief_artifact` validates any `report_state=<value>` arg against the enum.

## Required-field matrix

Each state constrains which other debrief fields must be populated — Chanakya relies on these to route:

| State | Required fields (in addition to debrief defaults) |
|---|---|
| `done` | `branch.merge_sha` (non-null); `argus_review.status` in `{approved, skipped, not-invoked}`; `debt.*` all false |
| `done_with_concerns` | `branch.merge_sha` (non-null); at least one of `debt.*: true` OR `tests.skipped_because` non-null OR `known_issues` non-empty |
| `blocked` | `branch.merge_sha: null`; `known_issues` non-empty describing the blocker; `argus_review.status` NOT `approved` |
| `needs_context` | `branch.merge_sha: null`; `open_questions` non-empty naming the missing info; `brief_id` non-null (the brief that needs rework) |

Validator warns on mismatch; block-tier reserved for clear contradictions (e.g., `state: done` + no merge_sha).

## Worker emission

Before writing the debrief, the worker picks the state:

```
report_state=$(
  # done?
  if [[ merge clean AND argus approved AND no debt ]]; then echo done
  # blocked?
  elif [[ no merge AND hard stop ]];                   then echo blocked
  # needs_context?
  elif [[ no merge AND brief incomplete ]];            then echo needs_context
  # default
  else                                                 echo done_with_concerns
  fi
)
scripts/lib-ledger.sh ... report_state=$report_state ...
```

Workers must NEVER choose `done` to make a red build look green — R10 (REVIEW.md) catches that failure mode at the evidence layer. The worker-report contract catches it at the structural layer. Both fire independently.

## Manager ingestion

The manager inbox sweep reads `report_state` and branches:

- `done` → `task → done`; continue sweep.
- `done_with_concerns` → `task → done` + concerns appended to status dashboard + push-queue entry if debt crosses threshold.
- `blocked` → `task → blocked`; push-queue entry; banner.
- `needs_context` → `task → needs_brief_rework`; regenerate brief; if brief state returns to `ready`, re-dispatch on next sweep.

## Interactions

- **R10 (REVIEW.md)** — verification-evidence rule. `done` implies the evidence fields are present.
- **Two-stage Argus (#80)** — spec-compliance `fail` maps naturally to `done_with_concerns` (merged but reviewer noted divergence) or `blocked` (reviewer blocked merge).
- **Build-debt (`_shared/schemas/build-debt.md`)** — `done_with_concerns` is the standard carrier for `build: true` / `test_unit: true`.
- **Review context and evidence hardening (#537, #604, #605, #606)** — reviewer findings declare context scope and risk metadata; worker responses consume that metadata, preserve test/runtime evidence distinctions, and escalate same-host or uncertain high-change-risk loops instead of blindly applying fixes.
- **Refactoring pressure (#607):** self-review can surface cleanup pressure, but only required current-task refactors are folded into the implementation. Deferred design debt travels through `refactoring_pressure.deferred_follow_ups[]` and `follow_ups[]`.

## Telemetry

`debrief_emitted` events include `{report_state: <value>}` in their data payload (post-2.0.2). Enables Phase 3 budget-telemetry to correlate state distribution with model choice and prompt-caching hit rate.
