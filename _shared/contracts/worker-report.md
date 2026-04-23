---
name: Worker Report Contract
description: Four-state enum Achilles emits on every debrief so Chanakya routes deterministically instead of parsing prose. Extends `schemas/debrief.md` with an optional `report_state` field (default inferred back-compat). Drawn from obra/superpowers/subagent-driven-development.
type: contract
---

# Worker Report Contract (`report_state`)

Every debrief Achilles writes carries a `report_state` — the worker's structured answer to "what just happened and what should Chanakya do next?". Replaces prose-parsing inside the inbox sweep.

## The four states

| State | Meaning | Chanakya routing |
|---|---|---|
| `done` | Task complete, all verification green, nothing outstanding. | Mark task `done`; no follow-up. Normal close. |
| `done_with_concerns` | Task merged, but with caveats the user should see — build debt, skipped tests, deferred edge cases, Argus flags addressed but left residue. | Mark task `done`; surface concerns in `/chanakya status` dashboard; mint follow-ups from `follow_ups:` per normal. |
| `blocked` | Achilles could not merge. Requires user input, external dependency, or escalation. No merge occurred; no commits on base. | Mark task `blocked`; push to user (push-queue + /chanakya status banner); do not re-dispatch automatically. |
| `needs_context` | The brief was incomplete — a reference, spec, or decision Achilles needed was missing. Re-dispatch after Chanakya regenerates the brief with the missing info. | Mark task `needs_brief_rework`; Chanakya regenerates brief filling the gap; automatic re-dispatch once brief state returns to `ready`. |

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

## Achilles emission

At Step 11 of `achilles/modes/task.md`, Achilles picks the state before writing the debrief:

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

Achilles must NEVER choose `done` to make a red build look green — R10 (REVIEW.md) catches that failure mode at the evidence layer. The worker-report contract catches it at the structural layer. Both fire independently.

## Chanakya ingestion

`chanakya/modes/inbox-sweep.md` sub-step 0A reads `report_state` and branches:

- `done` → `task → done`; continue sweep.
- `done_with_concerns` → `task → done` + concerns appended to status dashboard + push-queue entry if debt crosses threshold.
- `blocked` → `task → blocked`; push-queue entry; banner.
- `needs_context` → `task → needs_brief_rework`; regenerate brief; if brief state returns to `ready`, re-dispatch on next sweep.

## Interactions

- **R10 (REVIEW.md)** — verification-evidence rule. `done` implies the evidence fields are present.
- **Two-stage Argus (#80)** — spec-compliance `fail` maps naturally to `done_with_concerns` (merged but reviewer noted divergence) or `blocked` (reviewer blocked merge).
- **Build-debt (`_shared/schemas/build-debt.md`)** — `done_with_concerns` is the standard carrier for `build: true` / `test_unit: true`.

## Telemetry

`debrief_emitted` events include `{report_state: <value>}` in their data payload (post-2.0.2). Enables Phase 3 budget-telemetry to correlate state distribution with model choice and prompt-caching hit rate.
