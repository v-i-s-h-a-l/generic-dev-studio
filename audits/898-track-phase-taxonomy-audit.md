---
issue: 898
parent: 818
related: 891
date: 2026-05-15
purpose: Decide whether the Studio v2 Project board Track and Phase taxonomy should stay as-is, gain a thin mapping layer, or migrate toward label-aligned workstreams.
recommendation: keep_taxonomy_extend_mapping
mutates_project_state: false
mutates_labels: false
---

# Issue #898 — Track and Phase taxonomy migration audit

Walks the current relationship between the Project board's `Track` / `Phase`
single-select fields and the `track:*` / `phase-*` label families, identifies
the friction points the implementation arc (#818 / #891) intentionally
deferred, and recommends a direction the next board-maintenance change can
follow without breaking the board portability contract.

This audit reads state only. It does not mutate Project items, labels, or
Project field definitions, per the issue's non-goals.

## What the two axes mean today

| Surface | Authority | Scope |
|---|---|---|
| Project `Track` | `profiles/generic-dev-studio/project-board.yaml` (durable) and the Projects v2 single-select field on `Studio v2 transition` | Per-project. Other studio-managed projects use their own track value set per the per-project board portability contract in `PM-SURFACE.md`. |
| Project `Phase` | Same profile; same Projects v2 field | Per-project, opaque to cross-project tooling. |
| `track:*` labels | Repository labels | Issue-list filter axis. Travels in the issue body / search UI. No board awareness. |
| `phase-*` labels (e.g. `phase-2`, `phase-2-5-followup`, `phase-2-6-followup`, `phase-2.7-epic`) | Repository labels | Legacy v1 / phase-2.x grouping. Pre-dates the Projects v2 board's `Phase` field. |
| `theme/*` labels | Repository labels | Outcome-pillar grouping. Orthogonal to track/phase; not in scope here. |
| `chain/*` labels | Repository labels | Per-chain run grouping for chained issues. Orthogonal to track/phase. |

`PM-SURFACE.md` §Source-Of-Truth Map already states the canonical split:
labels own issue-list filtering, the Project `Track` field owns PM grouping.
That contract is what this audit re-validates rather than relitigates.

## Current Track and Phase value sets

From `profiles/generic-dev-studio/project-board.yaml`:

- **Tracks:** `A substrate`, `B PM surface`, `C agent topology`, `D chain mode`,
  `v1 forge-safety`, `v1 apollo`, `backlog`.
- **Phases:** `B1`, `B2`, `B3`, `B4`, `A0`, `A0.5`, `A1`–`A11`, `C`, `D`, `v1`.

These values are Studio-v2-specific. They encode the four parent arcs of the
v2 transition (`A`/`B`/`C`/`D`), the two `v1`-era tracks the board still
surfaces for archival continuity (`v1 forge-safety`, `v1 apollo`), and a
catch-all `backlog`. Phases are scoped under their track letter.

## `track:*` label inventory (active labels)

`track:apollo`, `track:branch-discipline`, `track:build-opt`,
`track:forge-safety`, `track:host-agnostic`, `track:pm-surface`,
`track:plan-chain-quality`, `track:skill-distribution`, `track:v2`,
`track:workflow`.

## Label-to-Track inference today

`scripts/lib-project-board.sh` → `project_board_infer_track_from_labels` maps
exactly three labels:

```
track:pm-surface   -> B PM surface
track:apollo       -> v1 apollo
track:forge-safety -> v1 forge-safety
```

Any other `track:*` label, or a mix of multiple `track:*` labels with no
unambiguous mapping, returns an empty string. Callers (currently
`scripts/studio-project-add.sh`) then require an explicit `--track`. That is
the symptom #818 closed against and #891 surfaced again: the inference is
correct but narrow, and most issues filed through `scripts/studio-gh-issue-new.sh`
need an explicit `--project-track` flag or fall into `Track=backlog`.

## Observed correlation on the board

Spot-walked the live `studio-project-state.sh --json` output across the
~200 items the board surfaces. Patterns that matter for this decision:

1. **`track:pm-surface` is faithful.** Items with `track:pm-surface` reliably
   carry `Track=B PM surface` on the board (e.g. #443, #498, #694, #891–#896,
   #898, #908). The single explicit mapping in the helper is already paying
   for itself.
2. **`track:apollo` and `track:forge-safety` are faithful but quiet.** Both
   tracks finished their `v1` arc; new issues are rare. The mapping is still
   correct and worth keeping.
3. **`track:v2` is a meta-label, not a Track.** It spans `A substrate`,
   `B PM surface`, `C agent topology`, and `D chain mode` board items. It
   correctly has no Track mapping; it should keep playing the umbrella role.
4. **`track:workflow` overwhelmingly maps to `D chain mode`.** Of items
   carrying `track:workflow`, the vast majority land on `Track=D chain mode`
   when triaged by a human (e.g. #446, #646–#654, #885), and several land on
   `Track=A substrate` with `Phase=A11` (#672–#678) for substrate-coupled
   chain work. The current inference returns empty, so every one of these
   issues needs `--track` at file time or a human board edit later.
5. **`track:host-agnostic` maps to `A substrate` `Phase=C`.** Issues #814–#817
   carry `track:host-agnostic` and sit on `A substrate` `Phase=C`. Again, no
   automatic inference today.
6. **`track:branch-discipline` lands in `backlog` `Phase=D`.** All seven
   #780–#786 items carry the label and are on `Track=backlog` `Phase=D`.
   They are real chain-mode work that the helper currently can't route.
7. **`track:build-opt`, `track:skill-distribution`, `track:plan-chain-quality`**
   have no live mapping. Items using them today are either closed or sit on
   `Track=backlog`.
8. **`Phase=D` on `Track=backlog` is the dominant default.** A large fraction
   of recently filed items carry `Track=backlog` `Phase=D`. Some of these are
   legitimate chain-mode work that should be `Track=D chain mode`; others are
   genuine backlog with no real phase and are getting `D` as a default
   artifact. The Phase field is doing two jobs at once for those rows.

## Mismatch summary

| Mismatch class | Symptom | Root cause |
|---|---|---|
| **Narrow Track inference** | Issues filed via `scripts/studio-gh-issue-new.sh` without `--project-track` end up `Track=backlog` even when their `track:*` label is unambiguous. | Inference map covers 3 of 10 active `track:*` labels. |
| **Multi-label ambiguity** | Issues with `track:pm-surface,track:workflow` (e.g. #893, #895, #896, #818, #898) resolve cleanly today only because `track:pm-surface` wins; if `track:workflow` were also mapped, the function would return empty. | `project_board_infer_track_from_labels` requires a single unique mapping and is silent on prioritisation. |
| **Backlog catch-all hides real Tracks** | `Track=backlog` rows hold a mix of real chain-mode work (would be `D chain mode`) and genuine deferred-no-track items. | No mapping for `track:branch-discipline` / `track:workflow` and no separate "no-track" sentinel distinct from "deferred work". |
| **Phase D default is overloaded** | `Phase=D` on `Track=backlog` is used both as "chain-mode batch" and as "filler because Phase is required". | The board never expressed a "no phase yet" option; planners filled `D` because it was the most recent batch. |
| **Phase axis is not portable** | Phase values are entirely v2-internal (`A0.5`, `A11`, `B3`, etc.). Cross-project tooling already treats Phase as opaque, but readers (`--by-phase`) still group with no awareness that some phases are sub-track batches and some are track-letter codes. | The board's Phase field encodes ordering inside a Track; cross-track grouping by `Phase=C` mixes `A substrate` Phase C work and `C agent topology` Track items. |

None of these mismatches are correctness bugs in the board portability
contract. They are issue-filing automation gaps and a small amount of value
overlap in `Phase=D`.

## Options considered

### Option 1 — Keep taxonomy as-is, do nothing

- **Pros:** Zero churn. Board portability contract is stable; other projects
  (e.g. turnip-ios) can declare their own track/phase set without studio
  having to first migrate.
- **Cons:** Continues the issue-filing friction that #818 / #891 deferred.
  New `track:*` labels still require `--project-track` on every
  `studio-gh-issue-new.sh` call. `Track=backlog` keeps absorbing
  chain-mode work.
- **When this is right:** if a board redesign is imminent (e.g. Phase 2.7
  triggers a new arc set), the inference patch would be thrown away.

### Option 2 — Extend the label-to-Track mapping layer (recommended)

- **Pros:** Cheapest fix that removes most of the observed friction. No
  Project field changes, no label renames, no historic board edits. Keeps
  the per-project portability contract intact: the mapping table lives in
  the project profile, not in core studio code.
- **Cons:** Slightly grows the mapping logic and forces an explicit
  tie-break rule when an issue carries multiple `track:*` labels (e.g. the
  common `track:pm-surface,track:workflow` pair). The tie-break must be
  documented so it does not become an implicit precedence rule.
- **Concrete shape:**
  - Move the inline `jq` map in
    `scripts/lib-project-board.sh:project_board_infer_track_from_labels` to a
    data-driven table sourced from the project board profile
    (`profiles/<slug>/project-board.yaml`), under a new optional
    `track_label_map` block:

    ```yaml
    track_label_map:
      track:pm-surface: "B PM surface"
      track:workflow: "D chain mode"
      track:branch-discipline: "D chain mode"
      track:host-agnostic: "A substrate"
      track:apollo: "v1 apollo"
      track:forge-safety: "v1 forge-safety"
    track_label_priority:
      - track:pm-surface
      - track:workflow
      - track:branch-discipline
      - track:host-agnostic
      - track:apollo
      - track:forge-safety
    ```

  - The library reads `track_label_map`; when multiple labels match, the
    `track_label_priority` order picks the winner. Unmapped labels still
    return empty so the existing `--track` requirement kicks in.
  - `track:v2`, `track:build-opt`, `track:skill-distribution`, and
    `track:plan-chain-quality` stay unmapped on purpose. `track:v2` is a
    meta-label; the other three have no live arc on the board and would
    create noise.
- **Side benefit:** because the mapping is per-profile, turnip-ios (and any
  future project) can declare a different `track_label_map` without forking
  studio code. That is the portability outcome `PM-SURFACE.md` already
  promised for the field values themselves.

### Option 3 — Rename Track values to align 1:1 with `track:*` labels

- **Pros:** Cosmetically simpler; `Track == track:<slug>` after the rename.
- **Cons:**
  - Breaks every board reader and dashboard that has memorised the current
    Track names (including documented examples in `PM-SURFACE.md`,
    `studio-project-state.sh --by-track` output, and analysis docs in
    `~/.dev-studio/<project>/analysis/`).
  - Couples the per-project Track set to the GitHub label space, which the
    portability contract explicitly avoids — labels are repo-scoped while
    Track is per-project.
  - Requires a one-off mass mutation of historic Project items, which the
    issue's non-goals forbid in this audit and which is high-risk without a
    second-host review.
- **When this is right:** never, on current evidence. The Track field is
  doing useful work that the labels cannot: it groups items into the four
  parent arcs (`A`/`B`/`C`/`D`) which do not have 1:1 labels and intentionally
  span multiple `track:*` slugs each.

### Option 4 — Run a full board migration (rename Tracks + flatten Phase)

- **Pros:** Lets us collapse the `backlog` / `D` / `v1` overflow and rebuild
  the Phase axis around a portable concept (e.g. milestones).
- **Cons:** Largest possible blast radius. Requires:
  - A second-host plan/outcome review per `CLAUDE.md` §Cross-host phase
    review.
  - Renaming or remapping all Project items (forbidden in this issue).
  - Updating `studio-project-state.sh`, the readers' display strings, and
    every analysis doc that quotes Track / Phase values.
- **When this is right:** when the next major arc (e.g. release substrate
  v2 or Phase 2.7 substrate work) actually changes the parent-arc shape.
  That is the natural trigger to redesign the Track set; do not redesign
  speculatively.

## Recommendation

Adopt **Option 2 — keep the current Track and Phase taxonomy, extend the
label-to-Track mapping layer.** Do not run a board migration in this audit.

Reasoning:

1. The board's Track and Phase values are already correct expressions of the
   v2 transition's parent-arc shape. They serve the board's PM-grouping role
   well. The friction the implementation arc (#818 / #891) flagged is in the
   automation layer, not in the field values.
2. The portability contract in `PM-SURFACE.md` explicitly assumes per-project
   Track sets that diverge from the cross-project label vocabulary. Trying to
   collapse the two axes into one violates that contract for marginal gain.
3. Extending the inference map is a small, reversible change. If a future
   board migration happens, the mapping table moves with the profile and the
   table itself is throw-away.
4. The `Phase=D` overload on `Track=backlog` rows is real but is not a
   taxonomy problem; it is a default-value problem in the issue-filing helper.
   Surface it as a separate small follow-up rather than bundling it into a
   taxonomy migration.

## Recommended follow-ups (do NOT execute in this issue)

These are concrete, scoped follow-ups for the chain runner or a future planning
session to file as their own issues. They are deliberately small and
independent so each can be reviewed cross-host without coupling.

1. **Profile-driven `track_label_map` and `track_label_priority`.** Implement
   Option 2 above. Touches `scripts/lib-project-board.sh`,
   `scripts/studio-project-add.sh` (no behavioural change at call site),
   `profiles/generic-dev-studio/project-board.yaml`, and
   `tests/contracts/test-project-board-portability*.sh` (if present, otherwise
   add a fixture). Documentation update in `PM-SURFACE.md` §Project Writer
   Contract to note the new optional fields and the priority-list semantics.
2. **Fix the `Phase=D` default.** Audit `scripts/studio-project-add.sh` /
   `scripts/studio-gh-issue-new.sh` for any path that sets `Phase=D` when no
   phase is provided. Either drop the default (let Phase be unset) or use a
   sentinel value like `none` only after explicit Project field expansion. Do
   not silently rewrite historic items.
3. **Document the `track:v2` umbrella role.** Add a one-paragraph note in
   `PM-SURFACE.md` §Source-Of-Truth Map clarifying that `track:v2` is a
   meta-label spanning multiple Project Tracks and intentionally has no
   inference mapping. Prevents future agents from "fixing" the apparent gap.
4. **Optional: triage the unmapped `track:*` labels.** `track:build-opt`,
   `track:skill-distribution`, and `track:plan-chain-quality` have no live
   board presence. Either retire the labels with a one-line note in the label
   description, or wire them into the mapping table only if a new arc surfaces.
   Defer until a triggering issue arrives.

## Acceptance check against the issue scope

| Issue acceptance line | Audit outcome |
|---|---|
| Compare current Project Track / Phase values with existing `track:*` labels. | Done — see "Current Track and Phase value sets", "`track:*` label inventory", "Observed correlation on the board". |
| Identify mismatches that hurt planning, reporting, or issue filing automation. | Done — see "Mismatch summary". Five mismatch classes named with root cause. |
| Propose either keeping the current taxonomy, adding a mapping layer, or running a board migration. | Done — see "Options considered" and "Recommendation". Recommendation is "keep taxonomy, extend mapping layer". |
| Do not mutate existing Project items in this issue. | Honoured — audit is read-only. |
| Do not rename labels or Project fields before the migration decision is accepted. | Honoured — no label or field-definition changes proposed inside this issue's scope. |
