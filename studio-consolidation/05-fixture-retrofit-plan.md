# Fixture Retrofit Plan

**Session F8 artifact.** Schedule for retrofitting the 23 mode packs currently emitting `W_MISSING_PACK_FIXTURE` per the Phase 2.6.6 skill-testing gate. Not the retrofit itself — the plan.

## Why

The 2.6.6 Iron Law (`_shared/primitives/skill-testing.md`) requires every mode pack to carry a test-mode-pack fixture. The linter warns (`W_MISSING_PACK_FIXTURE`) but doesn't block. Over time the warnings dilute signal. Retrofit gets them to zero.

**Not urgent:** warnings have been tolerable during Phase 2.5/2.6/2.6.6/2.6.5 work. Retrofit is a background batch, not a blocker.

## What's missing (2026-04-24)

23 packs across three surfaces:

- **Achilles (9):** `app-store`, `build`, `debrief`, `group`, `next`, `push-tf`, `studio-feedback`, `test-suite`, `worker`.
- **Chanakya (13):** `brief`, `compact`, `feedback-reports`, `feedback`, `ingest`, `intake`, `review`, `ship`, `sweep-debt`, `sweep`, `sync-slack`, `update`, `verify`.
- **Studio (1):** `studio/SKILL.md` router-level fixture.

## Batches

Group by domain so a session can context-switch once and knock out 3–5 related fixtures:

| Batch | Packs | Domain |
|---|---|---|
| B1 | `achilles/modes/{app-store,push-tf,debrief}.md` | Release / debrief workflow |
| B2 | `achilles/modes/{build,test-suite,worker}.md` | Build + test + fleet |
| B3 | `achilles/modes/{group,next,studio-feedback}.md` | Task-shape + capture |
| B4 | `chanakya/modes/{brief,intake,update}.md` | Planning lifecycle |
| B5 | `chanakya/modes/{review,verify,ship}.md` | Review + verify + ship |
| B6 | `chanakya/modes/{sweep,sweep-debt,compact}.md` | Sweep + debt + compact |
| B7 | `chanakya/modes/{feedback,feedback-reports}.md` | Feedback surfaces |
| B8 | `chanakya/modes/{sync-slack,ingest}.md` + `studio/SKILL.yaml` | Ingest + router |

8 batches of 2–3 packs each. ~60–90 min per batch at typical fixture-authoring pace.

## Per-fixture quality bar

Each fixture must:

1. Pick a scenario the pack is **load-bearing for** — not a generic "summarize the mode" prompt. See `_shared/primitives/skill-testing.md` §"Authoring a fixture".
2. Include `failure_signals` that a subagent without the pack will predictably exhibit. Narrow regexes.
3. Include `success_signals` that the pack's invariants produce. Names, numeric caps, event names where applicable.
4. Pass `scripts/test-mode-pack.sh run <pack>` on a real invocation before landing. Baseline-validation discipline.

Do **not** ship a fixture that only exists to silence the linter. A fixture where the `without` run accidentally succeeds is worse than no fixture — it creates a false signal of coverage.

## When to execute

- **Not during active phase work.** Batches run as background fillers between phases.
- **At most one batch per session.** Fixture-authoring requires fresh subagent runs (rate-limit budget).
- **Opportunistic during low-intensity sessions.** "Nothing pressing, let's take a batch" — don't schedule, don't force.
- **Reprioritize if a pack is about to be touched.** If B5 is pending and `chanakya/modes/ship.md` is about to get a substantive edit, move ship's fixture to this session so the edit carries it.

## GH tracking

Issue filed: [#95](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/95) `[2.6.6 retrofit] Fixture backlog for 23 mode packs` (`phase-2`, `polish`). Close the issue when the linter reports `0 warnings` on the `W_MISSING_PACK_FIXTURE` code. Sub-batches are checkbox-tracked in the issue body.

## Not in scope

- **Retroactive fixture for `ARGUS/SKILL.md`** — already shipped.
- **Ship.md composite coverage** — the composite is a wrapper over the fleet-dispatch path; fixture it once for the `ship` mode itself and rely on the achilles-worker fixture for the downstream fleet behavior. Do not over-cover.
- **Primitives without mode-pack dispatch.** The linter only enforces on mode packs; primitives are fixture-optional.

## Risks

- **Calcification risk.** Fixtures that are too tightly coupled to current prose block legitimate mode-pack edits later. Keep regexes anchored but not brittle.
- **Rate-limit cost.** Baseline validation requires real subagent runs. Batch runs amortize the cost; ad-hoc single runs waste it.
- **Broken baselines.** A fixture where the `without` run succeeds is a sign the pack isn't load-bearing — either the scenario is wrong, or the pack is redundant. Rewrite the scenario; if no harder scenario exists, consider deleting the pack.

## Success criteria

- `bash scripts/lint-architecture.sh` reports `W_MISSING_PACK_FIXTURE` count = 0.
- `scripts/test-mode-pack.sh run-all` passes on any opt-in full-sweep run.
- GitHub issue closed with a one-line note per batch completion in its history.
