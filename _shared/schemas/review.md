---
name: Review Schema
description: YAML shape for Argus and user verdicts under plans/reviews/<review-id>.yaml. Covers pre-merge code reviews, user-testing rounds results, and release-gate reviews.
type: reference
---

# Review Schema (`review@1.2.0`)

Per-review artifact written to `~/.dev-studio/<project>/plans/reviews/<review-id>.yaml`. Each review targets a subject (a task, a round, a release) and carries a verdict + findings list. Argus emits reviews on task merges; Chanakya emits them on round aggregates; the user emits them via `/chanakya review-feedback`.

## Shape

```yaml
schema_version:
  name: review
  version: 1.2.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77        # UUIDv7
subject:
  kind: task                                     # task | round | release
  id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11       # UUIDv7 of the subject
reviewer: argus                                  # argus | user | chanakya
stage: quality                                   # spec | quality (Argus two-stage; omit for user/chanakya reviewers)
state: approved                                  # pending | in-progress | approved | flagged | blocked | acknowledged
requested_at: 2026-04-22T12:41:10Z
completed_at: 2026-04-22T12:45:30Z
verdict: approved                                # approved | flagged | blocked | null (while pending/in-progress)
findings: []
checks_run:
  - name: regression_risk
    result: pass
  - name: secrets_in_diff
    result: pass
  - name: base_staleness
    result: pass
  - name: edge_case_coverage
    result: pass
scope:
  context_scopes: [diff-only, task-context]       # diff-only | task-context | plan-context | architecture-context | runtime/evidence-context
  diff_size: 187
  file_count: 4
  caps_triggered: []                             # array of {cap, value, limit}
notes: null
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. Version 1.2.0 adds structured review context and risk metadata for non-trivial findings. |
| `id` | string (UUIDv7) | yes | |
| `stage` | enum \| absent | no | `spec` \| `quality`. Set for Argus two-stage reviews (see `argus/modes/{spec-compliance,code-quality}.md`). Absent for user/chanakya reviewers. Missing in pre-1.1.0 reviews is read as `quality` for back-compat. |
| `subject` | object | yes | `{kind, id}`. `kind ∈ {task, round, release}`. `id` must resolve to an artifact of that kind. |
| `reviewer` | enum | yes | `argus` \| `user` \| `chanakya`. User-emitted reviews come from `/chanakya review-feedback`. |
| `state` | enum | yes | Per `state-machines/review-lifecycle.md`: `pending` \| `in-progress` \| `approved` \| `flagged` \| `blocked` \| `acknowledged`. |
| `requested_at` | RFC3339 UTC | yes | When the review was invoked. |
| `completed_at` | RFC3339 UTC \| null | yes | Null while `pending` / `in-progress`. |
| `verdict` | enum \| null | yes | `approved` \| `flagged` \| `blocked` \| null (while pre-terminal). Redundant with `state` for terminal verdicts; separates intent (state) from ruling (verdict). |
| `findings` | array | yes | Per-finding `{rule, tier, message, severity, likelihood, impact, change_risk, confidence, basis, recommended_action, path?}`. See §Findings. |
| `checks_run` | array | yes | Per-check `{name, result}`. `result ∈ {pass, fail, skip, warn}`. |
| `scope` | object | yes | `{context_scopes, diff_size, file_count, caps_triggered}`. Records what Argus saw — useful for dashboards and rule-effectiveness analysis. |
| `notes` | string \| null | yes | Optional reviewer commentary. |

## Context Scope

Reviewers declare every context class actually loaded:

| Scope | Meaning |
|---|---|
| `diff-only` | The reviewer inspected only the diff and local rulebook. |
| `task-context` | The reviewer also inspected the bounded task or issue contract. |
| `plan-context` | The reviewer also inspected phase, chain, or planner artifacts. |
| `architecture-context` | The reviewer also inspected architecture contracts or role topology. |
| `runtime/evidence-context` | The reviewer also inspected command output, test evidence, traces, logs, or review artifacts. |

Do not load full architecture context by default. Declare narrow scope honestly; escalate uncertainty instead of overstating confidence.

## Findings

Each finding records one review-rule hit:

```yaml
findings:
  - rule: R1_new_permission_surface
    tier: ask
    severity: high
    likelihood: likely
    impact: high
    change_risk: medium
    confidence: medium
    basis: diff-only
    recommended_action: needs_manager_planner_decision
    message: "Diff writes to /tmp/foo — outside ~/.dev-studio/**. Confirm or relocate."
    path: "scripts/new-thing.sh"
  - rule: R5_bash_portability
    tier: block
    severity: blocker
    likelihood: confirmed
    impact: high
    change_risk: low
    confidence: high
    basis: runtime/evidence-context
    recommended_action: fix_now
    message: "Uses `shopt -s nullglob` in a file that may be sourced from zsh."
    path: "scripts/lib-paths.sh"
```

- `rule` — stable identifier from `rules/review-rules.md` (e.g. `R1_new_permission_surface`, `R3_path_resolution`).
- `tier` — `block` \| `auto-fix` \| `ask` \| `warn`. Drives the verdict: any `block` → `blocked`; any `ask` unresolved → `flagged`; otherwise `approved`.
- `severity` — `blocker` \| `high` \| `medium` \| `low` \| `info`. Derive this from likelihood, impact, basis, and fix change risk; prose tone is not an input.
- `likelihood` — `confirmed` \| `likely` \| `plausible` \| `uncertain`.
- `impact` — `critical` \| `high` \| `medium` \| `low`.
- `change_risk` — `high` \| `medium` \| `low`. Risk that applying the requested fix breaks broader contracts or undoes the accepted plan.
- `confidence` — `high` \| `medium` \| `low`.
- `basis` — one context-scope enum naming the strongest context used for that finding.
- `recommended_action` — `fix_now` \| `accepted_with_modified_fix` \| `rejected_with_rationale` \| `needs_manager_planner_decision` \| `deferred_follow_up`.
- `message` — human-readable context, ≤ 300 chars.
- `path` — optional file-relative reference; may include `:line` suffix.

### Severity rubric

| Severity | Use when |
|---|---|
| `blocker` | Confirmed or likely correctness, contract, secret, permission, data-loss, or regression risk with high/critical impact. |
| `high` | Likely high-impact problem, or plausible critical problem with strong basis. |
| `medium` | Plausible behavior or maintainability risk with medium impact, or high impact with low confidence. |
| `low` | Local polish, clarity, or narrow edge-case concern with low impact. |
| `info` | Observation only; no requested fix. |

High `change_risk` plus `likelihood: uncertain` MUST recommend `needs_manager_planner_decision` or `deferred_follow_up`, not `fix_now`.

## Verdict derivation

Argus computes verdict from findings:

| Condition | Verdict |
|---|---|
| Any finding with `tier: block` | `blocked` |
| No `block`, at least one `ask` or `warn` | `flagged` |
| Empty findings, all checks pass | `approved` |

User-emitted reviews (from `/chanakya review-feedback`) set verdict directly — no derivation.

Risk metadata does not weaken blocks. It explains why the finding is blocking, warning-only, or escalation-worthy. Reviewers keep true correctness, contract, or regression blockers as `tier: block`.

## Lifecycle

Per `state-machines/review-lifecycle.md`:

```
pending → in-progress → {approved | flagged | blocked} → acknowledged
```

Transitions emit `review_state_changed` + the existing `review_approved` / `review_flagged` / `review_blocked` events per `contracts/events.md`.

## Links

- `subject` back-references the task / round / release. Bidirectional:
  - `subject.kind = task` ⇒ `task.links.reviews` contains `review.id`.
  - `subject.kind = round` ⇒ `round.reviews` contains `review.id`.
  - `subject.kind = release` ⇒ `release.reviews` contains `review.id`.
- Validator enforces both directions.

## Migration note (2.6)

Pre-2.6 Argus review output lived in free-form markdown under the worktree (`.argus/review.md`). Those files are archived as-is to `archive/2026-pre-2.6/` per Q18 — the verdict was the authoritative signal (captured in events), and the prose is historical context only. New reviews emit directly to YAML.

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.2.0 | 2026-05-05 | Adds `scope.context_scopes` and per-finding `severity`, `likelihood`, `impact`, `change_risk`, `confidence`, `basis`, and `recommended_action` for #606. Cross-references #537 review scope, #604 test evidence, and #605 same-host self-review. |
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing. |

## Related

- `state-machines/review-lifecycle.md` — authoritative transitions.
- `rules/review-rules.md` — source of finding `rule` identifiers.
- `schemas/task.md` / `schemas/round.md` / `schemas/release.md` — subjects a review can target.
- `contracts/events.md` — `review_*` events.
