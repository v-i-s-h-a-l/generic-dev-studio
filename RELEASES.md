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
- **Lead with the verb.** "Run the studio on multiple projects…" not "The studio now supports…". Active, not passive.
- **Plain language — 10-year-old test.** If a word needs explaining to a 10-year-old, pick a different word. "Orchestrator" → "manager". "File-based IPC" → "a shared inbox". "Atomic claim" → "first-come-first-served".
- **Workflow-first.** Ask: *what can the user do now that they couldn't before? what got easier? what got faster?* If a bullet doesn't answer one of those, cut it or move it to Changes.
- **Examples sparingly.** One short example under a bullet is fine when the bullet alone is abstract. Not every bullet needs one. When in doubt, no example.
- **One line per bullet.** If a bullet needs more than one line, you're probably mixing two points — split them.

### Tone check

Read each bullet aloud. Red flags:
- Implementation terms (`resolve_inbox_root`, `fswatch`, `lib-paths.sh`) → replace or remove.
- Refactor language ("refactored", "extracted", "generalized") → the user doesn't care *how*. Say *what it unlocks*.
- Commit counts, file counts, line counts → meaningless to the user.
- Sounds like a commit message → rewrite from the user's point of view.

### Good vs bad examples

**Bad**:
> *Refactored path resolution into `scripts/lib-paths.sh` and added helper functions. Updated 14 files to route through it. Added `detect_stack()` for phase-2 consumers.*

**Bad (too wordy, prose-form)**:
> *Each project you use the studio on now runs its own independent Achilles fleet. Before this release, worker inboxes, push queues, and fleet state all shared one machine-global location — fine for one project, a mess the moment two projects tried to share a machine. Now the studio resolves each project automatically…*

**Good**:
> - Run the studio on multiple projects at once — each gets its own workers, inbox, and queues.
> - Terminal tabs now show which project a worker belongs to (e.g. `turnip-ios:worker-1`).
> - No setup — the studio picks the right project from your git folder.

## Versioning

Semver (`MAJOR.MINOR.PATCH`). When proposing a bump, state *which rule triggered it* — forces explicit reasoning, catches mistakes.

### Decide the bump by asking three questions

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
- Additive → bump **MINOR**
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

### Pre-release suffixes

- `-beta.N` — shipping for feedback; interfaces may still shift
- `-rc.N` — release candidate; no changes expected unless bugs found

Drop the suffix when you're ready to call it stable. Don't ship public `-beta` indefinitely.

### When in doubt

Bump MINOR. The Migration section in "What's new" carries the weight if it's breaking. Don't fight the version number.

## Mechanics

GitHub release flow (once ready):

1. Ensure `main` is green (scripts pass `bash -n`, smoke tests pass, REVIEW.md rules satisfied).
2. Draft the release notes in this template — work on a scratch file first, not directly in the tag annotation.
3. Tag: `git tag -a vX.Y.Z -m "<title from notes>"` with an annotated tag, not a lightweight one.
4. Push: `git push origin vX.Y.Z`.
5. `gh release create vX.Y.Z --notes-file <scratch-file>` — publishes to GitHub with the markdown rendered.
6. Append the same notes to `CHANGELOG.md` (top of file, newest first).

Never tag without notes. Never tag a commit that's not on `main`. Never force-push or delete a published tag.
