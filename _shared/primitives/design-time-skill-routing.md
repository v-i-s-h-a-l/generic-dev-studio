---
name: Design-Time Skill Routing
description: Cross-cutting mechanic for mandatory skill invocation at implementation time and review time. Pre-edit routing (Achilles Step 4.0) + post-diff re-invocation (Achilles Step 5.0) + review-time routing (Argus Step 3.5). Verdict schema and commit-note invariant live here; stack-specific routing tables live in `_shared/rules/<stack>-skill-routing.md`.
type: primitive
---

# Design-Time Skill Routing

Self-review has systematic blind spots — wrong-shape APIs, wrong-pattern architecture, concurrency isolation bugs, framework-idiom violations, SDK-teardown ordering. Skills are the counterweight. This primitive makes their invocation **structural**, not opportunistic.

Adopted 2026-04-24 as part of the studio consolidation arc (Session F). Supersedes the opportunistic "invoke any skills the brief lists" prose that previously sat in Achilles Step 1.

## What "design-time" means

Two invocation points per task, plus a review-time checkpoint:

1. **Pre-edit (Achilles Step 4.0)** — before the first production edit, match the anticipated diff shape against the stack's routing table; load every matching skill; apply its guidance while writing.
2. **Post-diff (Achilles Step 5.0)** — after the diff exists, re-invoke the same skills against the *actual* diff; record each skill's verdict (clean / minor / material) in the debrief.
3. **Review (Argus Step 3.5)** — for any diff in the covered stack, Argus re-invokes the routing table against the actual diff and the "Design choices" commit note; findings are `FLAGS`, never `BLOCKS` (week-1 posture).

Pre-edit catches the "wrong shape from the start" bugs; post-diff catches the "looked right, wrote wrong" bugs; review catches the "Achilles invoked but rationalized" bugs.

## Contract with consumers

| Consumer | Reads | Writes |
|---|---|---|
| Achilles `task.md` Step 4.0 | This file + `_shared/rules/<stack>-skill-routing.md` for the active stack | First commit message carries a 2–4-line "Design choices" note |
| Achilles `task.md` Step 5.0 | Same routing table + the actual diff | Debrief `## Self-Review` block records per-skill verdict |
| Argus `code-quality.md` Step 3.5 | Routing table + Achilles's "Design choices" commit note + the diff | `FLAGS` entries with `rule: design/<category>` |

Stack selection is the project's concern: a project declares which stack it belongs to (Turnip iOS = Swift), and the mode pack reads the matching `<stack>-skill-routing.md`. For now the only stack is Swift (`_shared/rules/swift-skill-routing.md`). When a second stack arrives, the mode packs read from the matching rule file; the primitive doesn't change.

## Verdict schema

Each skill invoked in Step 5.0 emits one of:

| Verdict | Meaning | Action |
|---|---|---|
| `clean` | No finding; skill's guidance is satisfied. | Record in debrief; proceed. |
| `minor` | Style / non-load-bearing deviation. | Record in debrief; proceed. Argus may re-flag. |
| `material` | Design-level issue the skill was invoked to catch. | **Fix-then-rerun.** Do not rationalize. Do not proceed to Step 6 with a material finding open. |

`material` is load-bearing: it is the exact signal that distinguishes "skill caught a real problem" from "skill noted a nit." If a skill is tempted to mark something `material` but it's actually a nit, downgrade to `minor`; don't inflate. Conversely, if a finding will matter to a future maintainer, mark it `material` even if it feels costly to fix now.

## "Design choices" commit-note invariant

The first commit on any task touching the stack carries a 2–4-line "Design choices" section capturing:

1. Architecture decision (pattern chosen; why).
2. Key API-name choices (or "n/a — no new public surface").
3. Concurrency model (actor isolation, MainActor boundaries, Sendable posture — or "n/a — no concurrency changes").
4. Any deviation from the skill's recommendation, with reason.

Argus reads this note in Step 3.5:

- **Present and matches diff** → no finding.
- **Present but contradicts diff** → `design-drift` flag.
- **Missing on a diff that should have had one** → `design-accountability-missing` flag.

"Should have had one" = the diff triggered at least one row in the stack routing table.

## Fix-then-rerun rule (material findings)

When Step 5.0 surfaces a `material` finding:

1. Fix the issue in a new commit. Do not amend the "Design choices" commit.
2. Re-run Step 5.0 against the new diff. All skills — not just the one that flagged.
3. Re-emit verdicts in the debrief. A `material` verdict that has been fixed is still recorded with a note (`material → resolved in <sha>`); erasing history hides the skill's value.

No "I'll log it as a follow-up and ship" shortcut. If the skill said `material`, the skill was right by construction. If it was wrong, the skill's table is miscalibrated — fix the table (separate commit) and rerun.

## Token cost posture

This primitive is referenced, not inlined. Achilles Step 4.0 pulls it on-demand; the stack routing table is separate and only loaded if the diff intersects the active stack. The routing table itself stays small (diff-signal → skill-name, one row per signal). Do not bloat the table with guidance; guidance lives in the skill itself.

## Stack routing tables

Current tables:

| Stack | Table | Applies to |
|---|---|---|
| Swift | `_shared/rules/swift-skill-routing.md` | Any Swift / SwiftUI / IMGLY diff |

When a second stack arrives, add a row here and author the sibling rule file. No primitive changes needed.

## Fixture

`tests/primitives/design-time-skill-routing.yaml` — scenario pressures a fresh subagent to decide how design-level concerns get routed. Without the primitive, subagent leans on generic engineering intuition (ad-hoc skill invocation, no verdict schema, no commit-note invariant). With it, the subagent names Step 4.0 / 5.0 / 3.5, the three verdict states, and the fix-then-rerun rule.

## Relationship to existing rules

- **`_shared/router-pattern.md`** — the general dispatch mechanic this primitive specializes.
- **`_shared/rules/review-rules.md`** — Argus Step 3.5 findings go through the same `FLAGS`/`BLOCKS` pipeline; this primitive only adds signals.
- **`_shared/primitives/skill-testing.md`** — the 2.6.6 gate applies to this primitive too; hence the fixture above.

## Explicitly not in scope

- Model routing (#65 — task size / kind → model recommendation). Different input space; sibling primitive.
- Runtime-detected skill failures. A skill that fails to load is a host-adapter concern, not a routing concern.
- Multi-stack routing (a single diff touching two stacks). Will happen rarely; when it does, consumers read both tables and take the union.
