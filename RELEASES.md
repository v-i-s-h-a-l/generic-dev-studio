# Release Guide

Conventions for tagging and writing release notes for generic-dev-studio. Living doc.

The actual release log lives in `CHANGELOG.md` (created when the first tag lands). This file is just the rules and template.

## When to tag

Not every commit deserves a tag. Not every month deserves a tag. Cut a release when the repo crosses a user-visible milestone — someone who uses the studio should be able to upgrade and feel the difference.

### Tag-worthy signals (any one is usually enough)

- A new capability the user can reach from their workflow (new mode, new script, new command, new skill).
- A behavior change in existing commands (flag renamed, default changed, output format changed).
- Friction removed at a level the user will notice (fewer permission prompts, fewer manual steps, no more required config).
- A migration becomes necessary (paths moved, env vars renamed, files need to be relocated).
- A breaking change in any public-facing surface (SKILL.md sub-command removed or renamed, script CLI flag removed).

### Not tag-worthy on its own

- Internal refactor with no user-visible effect.
- Typo fixes, wording cleanups, doc-only touch-ups.
- Test additions with no behavior change.
- Single-file bug fixes that don't change observable behavior.

### Cadence heuristic

A rough feel (not a rule): if ≥3 tag-worthy commits have accumulated on main, or it's been ≥14 days since the last tag *and* there's at least one tag-worthy commit, surface it. Don't tag just because time passed — tag because the user will notice something.

### GitHub milestones

Use milestones for active release-worthy arcs, not for every possible future tag. Open one when an arc has a clear user-visible outcome, a hard planning gate, or enough scoped work that GitHub needs a native target. Leave `due_on` empty unless there is a real external deadline.

Name the milestone after the expected release and outcome, for example `v0.10.0 — PM surface readiness`, but treat the version as a planning label until the tag is cut. If a patch release ships first, the headline changes, or the arc splits, rename or split the milestone before release notes are drafted.

Assign only issues that clearly belong to that release target. Blocked follow-on arcs, ledgers, and unrelated hardening issues stay unassigned until their own release-worthy shape is active. Close the milestone after the GitHub release ships.

### How to suggest

When you (human or agent) notice the repo has crossed a tag-worthy threshold, surface one sentence:

> "Looks like a release-worthy point — 3 commits since `v0.1` add per-project fleets and fix the permission-prompt regression. Want me to draft `v0.2` notes?"

Don't auto-tag. Don't open a PR. Just surface the suggestion and let the user decide.

## Release notes template

```markdown
## vX.Y.Z — <YYYY-MM-DD>

### What's new
- <Bullet 1 — one-line capability or change from the user's point of view>
- <Bullet 2 — …>
- <Bullet 3 — …>

<Target: 3–6 bullets, one line each. If something needs an example
to be clear, add a short one below the bullet — indented, one line.
Not every bullet needs an example.>

### Migration
<Only include if the user must do something to upgrade. Step-by-step,
copy-pasteable. If nothing's required, delete this whole section.
Don't write "None".>

### Changes
<Technical detail for contributors. Commit-log-style. Group by area
if many (scripts/, chanakya/, achilles/, argus/, _shared/, docs).>
```

### Style rules for "What's new"

- **Bullets over prose.** Each bullet = one thing the user can now do, will notice, or will have to work around. Readers scan bullets; they skip paragraphs.
- **The user's outcome is the subject — not the feature.** Every bullet must answer one of: *what can I do now? what got easier? what goes away? what am I getting?* Bullets whose subject is the software ("Workers now…", "The inbox now…", "Terminal tabs now…") fail this test — rewrite with the user as the (implied) subject.
- **Plain language — 10-year-old test.** If a word needs explaining to a 10-year-old, pick a different word. "Orchestrator" → "manager". "File-based IPC" → "a shared inbox". "Atomic claim" → "first-come-first-served".
- **Lead with the outcome in bold, then one line of context.** Like `**Work on multiple projects at once.** No conflicts between them.` — the bold is what they're getting; the rest is the how-it-feels.
- **Workflow-first.** If a bullet doesn't change what the user does or notices, cut it or move it to Changes. Feature names without outcomes belong in Changes, not What's new.
- **Examples sparingly.** One short example under a bullet is fine when the bullet alone is abstract. Not every bullet needs one. When in doubt, no example.
- **One line per bullet** (not counting the optional sub-line). If a bullet needs more than that, you're probably mixing two points — split them.

### Subject-flip test

Before finalizing, read each bullet and ask: *who's the subject of this sentence?*
- If it's the software ("the studio now…", "workers…", "tabs…") → rewrite.
- If it's the user (implied "you") or an outcome ("no conflicts", "machine-wide status") → keep.

### Minor-bump headline rule

Every MINOR bump exists *because of* one specific feature (or closely related set). That feature is the reason a user should upgrade — it must be obvious from the notes.

- **Identify the triggering feature** before writing. If you can't name it in one sentence, the release probably shouldn't be a MINOR.
- **Give it the top bullet** under What's new. Don't bury it under smaller wins.
- **Add one example use case** — a short, concrete scenario showing how a user would actually reach for it. One example, one scenario, 1–2 lines. Use judgement: if the top bullet is already self-evident, skip the example. If the feature is abstract or might not be obvious *when* to use it, the example earns its keep.
- **Don't example-spam.** Only the triggering feature gets an example. Supporting bullets stay clean one-liners. Readers scan — over-examples dilute the headline.
- When commit metadata is available, start from `Changelog:` or the `Change-Type:` taxonomy (`feature`, `bugfix-shipped`, `bugfix-wip`, `regression-fix`, internal types) before hand-editing. If a release note falls back to subject/body because trailers are missing, mention that in the drafting notes.

Example of the rule applied:

> - **Work on multiple projects at the same time.** Each project's work stays separate — no accidental cross-talk.
>
>   *Example: you're deep in turnip-ios when a bug hits another app. Open the studio in the other project's folder — it gets its own workers and queue, and turnip-ios stays untouched.*
>
> - Know which pane is doing what. Tabs label themselves with the project name.
> - No setup when you switch projects.

### Major-bump extras

A MAJOR bump means *the tool works differently now* — users have to update their mental model, not just run a migration script. MAJOR notes need everything a MINOR has, plus:

- **"Why major?" section** — 2–3 sentences on what was rethought and why it couldn't be done as a MINOR. Forces discipline. If you can't write this paragraph, the bump is probably a MINOR.
- **Concept changes with Before/Now framing** — users have the old model baked in. Tell them what's no longer true. Format:
  > *Before: one Chanakya session drove tasks across all projects.*
  > *Now: each project runs its own Chanakya — `/chanakya status` only shows the current project.*
- **Migration effort estimate** — one line: `< 5 min` / `< 30 min` / `1–2 hours, includes re-reading SKILL.md files`. Users plan around effort, not instructions.
- **"Should you upgrade now?" call-out** — honest. If the migration is heavy or feedback is still coming in, recommend waiting for `vN.1`. Better to delay adoption than rush a regret.
- **Rollback path** — how to get back to `v(N-1)` cleanly if it goes poorly. State lives on disk in this repo; rollback is realistic, document it.
- **Prior deprecation preferred** — a MINOR a release or two ahead should mark the old behavior deprecated with a visible warning (a one-line stderr note from the affected script, or a banner in `/chanakya status`). The MAJOR removes it. Not always possible (clean-break refactors), but default to it.

#### Cadence rules for MAJORs

- **Rare by default.** If MAJORs land more than every ~2–3 months, decisions are off or the bump is being over-used. Re-read the "Why major?" justification with a skeptical eye.
- **Dogfood the migration** before tagging. Spin up a fresh `~/.dev-studio/scratch/`, run through the migration docs, see what's missing.
- **Smoke test the new model** end-to-end before tagging — not just `bash -n`. Prove the new mental model actually works.

#### Trim the bullets, not the rigor

A MAJOR doesn't need *more* What's new bullets than a MINOR — it needs *better-chosen* ones. Pick the 2–3 things that capture the model shift; let "Concept changes" carry the rest. Don't pad to feel important.

#### What MAJOR is not

If migration is mechanically simple and the mental model didn't shift, it's a MINOR (pre-1.0) or a strict MAJOR with a small footprint (post-1.0). Don't make MAJORs scary for their own sake — when migration is `< 5 min`, say so up top.

### Tone check

Read each bullet aloud. Red flags:
- Implementation terms (`resolve_inbox_root`, `fswatch`, `lib-paths.sh`) → replace or remove.
- Refactor language ("refactored", "extracted", "generalized") → the user doesn't care *how*. Say *what it unlocks*.
- Commit counts, file counts, line counts → meaningless to the user.
- Sounds like a commit message → rewrite from the user's point of view.

### Good vs bad examples

**Bad (technical, refactor-speak)**:
> *Refactored path resolution into `scripts/lib-paths.sh` and added helper functions. Updated 14 files to route through it.*

**Bad (prose, still feature-subject)**:
> *Each project now runs its own independent Achilles fleet. Worker inboxes, push queues, and fleet state are scoped per project…*

**Better (bullets but software-as-subject)**:
> - Terminal tabs now show which project a worker belongs to (e.g. `turnip-ios:worker-1`).
> - The studio now auto-resolves the project from your git folder.

**Good (user-as-subject / outcome-first)**:
> - **Work on multiple projects at the same time.** Each project's work stays separate — no accidental cross-talk.
> - **Know which pane is doing what.** Tabs label themselves with the project name and worker number.
> - **No setup when you switch projects.** The studio figures it out from your git folder.
> - **Check on everything in one place.** One command shows every worker across every project.

## Versioning

Semver (`MAJOR.MINOR.PATCH`). When proposing a bump, state *which rule triggered it* — forces explicit reasoning, catches mistakes.

### Decide the bump by asking these questions

**0. Is this a narrow follow-up to the current release arc?**
If yes → **PATCH**, even when the follow-up adds a small tool or report. Use this lane when all of these are true:
- The previous MINOR release already introduced the user-facing arc.
- The new work makes that arc safer, more measurable, or less painful without changing the mental model.
- There is no migration, no renamed surface, no new mode, and no new workflow family.

Examples: a diagnostic report for the freshly shipped Forge safety floor, a small status view that explains an existing queue, or a focused helper script that measures a just-released gate. This keeps narrow reliability follow-ups grouped under the release they clarify instead of pretending every small additive script starts a new arc.

**1. Does the user need to change anything to upgrade?**
If yes → **breaking**. Examples in this repo:
- Script flag removed or renamed
- SKILL.md sub-command removed or renamed (`/chanakya ship` gone)
- On-disk path moved (the `~/.dev-studio/.runtime/` → `<project>/.runtime/` refactor is exactly this)
- Env var removed or renamed
- Event log / task file / brief format changes that old agents can't parse

**2. Does this add a new way to do something that didn't exist?**
If yes → **additive**. Examples:
- New sub-command (`/chanakya feedback-archive`)
- New script
- New flag that preserves old default behavior
- New env var (`ACHILLES_DISPLAY_NAME`)
- New optional field in a schema

**3. Is this only fixing something broken, or a perf improvement with no behavior change?**
If yes → **fix**.

### Mapping to version bumps

**Pre-1.0** (we are here):
- Breaking → bump **MINOR** (0.1 → 0.2) + prominent Migration section in notes
- Additive → bump **MINOR**, except narrow follow-ups that satisfy question 0 → **PATCH**
- Fix → bump **PATCH**

Rationale: semver §4 says `0.y.z` is for "anything may change." Collapsing breaking and additive into MINOR avoids premature 1.0 churn without deceiving users — the Migration section carries the weight when it's breaking.

**Post-1.0**:
- Breaking → bump **MAJOR** (strict)
- Additive → bump **MINOR**
- Fix → bump **PATCH**

### When to cut 1.0

Don't rush it. Cut 1.0 when:
- APIs have stabilized (few breaking changes across 2–3 recent releases)
- At least one external user (not just you) depends on the repo
- You're willing to live with post-1.0 discipline (MAJOR bumps for every break)

Until then, staying in 0.x is honest and gives freedom to reshape.

#### `v1.0` is special

`v0.x → v1.0` is itself a MAJOR but with different semantics than later MAJORs: it's a **stability promise**. From 1.0 onward, the public surface (script CLIs, SKILL.md sub-commands, on-disk paths, env vars, schemas) won't break without another MAJOR.

`v1.0` notes should lead with what's being committed to stability — not what's new. Add a "Stability promises" section listing the surface that's now under contract. This is the headline for 1.0; new features take the back seat.

### Pre-release suffixes

- `-beta.N` — shipping for feedback; interfaces may still shift
- `-rc.N` — release candidate; no changes expected unless bugs found

Drop the suffix when you're ready to call it stable. Don't ship public `-beta` indefinitely.

### When in doubt

Bump MINOR. The Migration section in "What's new" carries the weight if it's breaking. Don't fight the version number.

## Mechanics

### Tags vs releases

Every public version tag (`vN.M.Z`, including `-beta.N` and `-rc.N`) gets a **GitHub release**, not just a git tag. Reasoning: this repo ships docs, not binaries — the release notes *are* the deliverable. Burying them in a tag annotation hides migration steps and makes them undiscoverable from the repo's "Releases" sidebar.

Tag-only is fine for **internal markers** (`pre-merge-test`, `scratch-before-refactor`, etc.) — anything that isn't a version someone might install or upgrade to.

### Standard release flow

1. Ensure `main` is green (scripts pass `bash -n`, smoke tests pass, REVIEW.md rules satisfied).
2. Draft the release notes in this template — work on a scratch file first (`/tmp/vX.Y.Z-notes.md`), not directly in the tag annotation.
   Start from `Changelog:` commit trailers when they exist; see `_shared/contracts/definition-of-done.md`. If trailers are missing, insufficient, or superseded, record that in the release packet instead of silently reconstructing notes from commit subjects.
3. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z — <short title>"` with an annotated tag, not a lightweight one.
4. Push the tag: `git push origin vX.Y.Z`.
5. Create the release: `gh release create vX.Y.Z --notes-file /tmp/vX.Y.Z-notes.md --title "vX.Y.Z — <short title>"`. Add `--prerelease` for `-beta.N` / `-rc.N`; omit for stable drops.

GitHub Releases is the canonical source — we don't maintain a `CHANGELOG.md` by default. Add one only when there's a real signal: a user asks for offline/greppable history, or the Releases UI starts feeling limited (~5+ releases). Until then, the duplication isn't worth the drift risk.

### Hard rules

- Never tag without notes (a release without notes is a tag — see above).
- Never tag a commit that's not on `main`.
- Never force-push or delete a published tag.
- Always set `--prerelease` for beta/rc; drop it only for stable. Lying about stability poisons trust.
- Always link the previous version in migration steps so users know what they're moving from.
