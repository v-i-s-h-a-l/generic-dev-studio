---
name: Skill Testing
description: Discipline for pressure-testing mode packs and shared primitives. For every pack, a scripted scenario where a fresh subagent WITHOUT the pack fails, and loading the pack flips it to pass. On-demand (not per-commit); real Claude subagent invocations.
type: primitive
---

# Skill Testing — the discipline

A mode pack or shared primitive earns its keep only if a subagent that lacks it gets the task wrong *and* a subagent that has it gets the task right. Everything else is wishful prose.

Adopted 2026-04-23 from `obra/superpowers/skills/writing-skills` + `testing-skills-with-subagents`. Gates Phase 2.7 knowledge-layer work.

## What a baseline looks like

A **baseline** is a YAML fixture pinned next to the thing it tests. It names a scenario concrete enough that two subagents — one with the pack, one without — can be scored against the same criteria.

Fixture path: `tests/mode-packs/<agent>/<mode>.yaml` (one per mode pack).  
Fixture path: `tests/primitives/<primitive>.yaml` (one per shared primitive, optional).

Required fields:

```yaml
schema: 1
pack: chanakya/modes/status.md                # path relative to repo root
scenario: |
  <natural-language prompt given to both subagents>
failure_signals:                               # regexes the WITHOUT run is expected to exhibit
  - "(?i)ask(s|ed)? for file path"
  - "(?i)hallucinat"
success_signals:                               # regexes the WITH run is expected to exhibit
  - "snapshots/"
  - "status-fallback-loaders"
notes: |
  Optional — why this scenario, what regression it would catch.
```

The driver (`scripts/test-mode-pack.sh`) composes the two prompts itself:

- **stripped run** — `scenario` + a denial instruction ("you do NOT have access to `<pack>` — do not Read it").
- **loaded run** — the pack file's full contents, a separator, then `scenario`.

Pass rule (hard-coded in driver, not per-fixture):

- `without`-pack run exhibits `failure_signals`.
- `with`-pack run exhibits `success_signals` AND lacks `failure_signals`.

## What counts as a pass

A fixture passes iff **both** runs come out as expected:

1. `without`-pack run exhibits `failure_signals` (confirms the scenario *needs* the pack — otherwise it's a trivial task and the pack isn't earning anything).
2. `with`-pack run exhibits `success_signals` AND lacks `failure_signals`.

A fixture where the `without` run *accidentally succeeds* is a **broken baseline**, not a successful pack. Rewrite the scenario to be harder, or delete the pack because it's unneeded.

A fixture where the `with` run still fails is a **regression** in the pack — block the commit.

## On-demand posture

Subagent invocations cost rate-limit quota. The driver runs:

- **On demand** — `scripts/test-mode-pack.sh run <pack>` or `run-all`. Humans opt in.
- **Never per-commit.** Pre-commit hook only validates fixture *syntax* via `--dry-run`, not real subagent runs.
- **Never in CI by default.** Nightly cron can opt in (`/schedule` + `run-all`), but not as a merge gate.

The lint gate (`E_MISSING_PACK_FIXTURE`) enforces *existence* of a fixture, not freshness of a result.

## Authoring a fixture

1. **Pick a scenario the pack is load-bearing for.** Not "summarize the mode" — a concrete *task* the pack guides through. For `chanakya/modes/status.md`, that's "produce a status report for project X" — the pack tells you to read snapshots first, fall back via loaders, cite events.

2. **Write the `stripped_prompt` to actively deny the pack's guidance.** Don't just omit the pack — instruct the subagent to NOT read `modes/status.md` or its referenced primitives. Otherwise a curious subagent defeats the baseline by reading the repo.

3. **Write narrow signals.** `"snapshots/"` is too loose — matches incidental mentions. `"reads .*snapshots/.*\\.json before"` is tighter. Prefer anchored regexes.

4. **Scaffold via `scripts/test-mode-pack.sh scaffold <agent>/<mode>`** — writes a skeleton with the pack auto-linked.

5. **Validate the baseline first.** Run `--dry-run` to confirm fixture parses. Then run the `stripped` half once and confirm it fails *as predicted* before trusting the `loaded` half.

## When to update a fixture

- Pack changes behavior → fixture signals may need updating. Run `test-mode-pack.sh run <pack>` before committing the pack change; if it fails, either fix the pack or update the fixture deliberately (commit message must note the signal change).
- Pack is renamed / merged / split → move / split / consolidate the fixture in the same commit. The lint gate catches orphans.
- New mode pack lands → fixture lands in the same commit. No retroactive baselines for new packs.

## Relationship to existing rules

- **REVIEW.md R6 (SKILL-in-sync)** — if the pack's prose changes, fixtures are in scope for review.
- **Token budget (mode frontmatter)** — fixtures don't burn session tokens (subprocess boundary). Budget telemetry is unaffected.
- **Capability manifest** — fixtures are *not* capabilities. Don't list them in `docs-surface.json`.

## Retroactive coverage

Phase 2.6.5 extracted 5 mode packs without baselines. Phase 2.6.6 retrofits them:

| Pack | Fixture | What it proves |
|---|---|---|
| `chanakya/modes/status.md` | `tests/mode-packs/chanakya/status.yaml` | Snapshot-first discipline, fallback loaders, fresh-event citation |
| `argus/SKILL.md` | `tests/mode-packs/argus/SKILL.yaml` | Scope caps honored, week-1 block-vs-flag posture, base-staleness check |
| `chanakya/modes/inbox-sweep.md` | `tests/mode-packs/chanakya/inbox-sweep.yaml` | Step 0A–0G enumeration, debrief ingest, no-skip on empty |
| `chanakya/modes/tests.md` | `tests/mode-packs/chanakya/tests.yaml` | Dirty-state guard, candidate scan, round linkage |
| `achilles/modes/task.md` | `tests/mode-packs/achilles/task.yaml` | Size-driven build gate, Argus pre-merge, merge-lock, debrief dual-write |

## Not a contract

This is a primitive (discipline + driver), not a message contract. It describes *how we test*, not *what flows between agents*. Message contracts live under `_shared/contracts/`.
