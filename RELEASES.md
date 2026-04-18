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
<2–4 short sentences in plain conversational language. No jargon. Focus on:
  - new capabilities the user can reach from their workflow
  - friction that went away
  - behavior they'll notice
Written as if explaining to a teammate who uses the studio but doesn't
touch its internals. One paragraph. No bullet lists unless 3+ items.>

### Migration
<Only include if required. Any steps the user must take — env vars to
set, dirs to move, configs to tweak. If nothing's required, delete this
section entirely. Don't write "None" — just omit.>

### Changes
<Technical detail. Commit-log-style. Group by area if many:
  - scripts/
  - chanakya/
  - achilles/
  - argus/
  - _shared/
  - docs
>
```

### Tone check for "What's new"

Before finalizing, read your paragraph as if you're a new Turnip dev who just ran `git pull` on the studio repo. Does it tell you what to do differently, or does it read like internal bookkeeping? If the latter, rewrite.

Leaks to watch for:
- Implementation terms (`resolve_inbox_root`, `fswatch`, `lib-paths.sh`) → promote to plain language ("path resolution", "file watcher").
- Refactor language ("refactored", "extracted", "generalized") → the user doesn't care *how*, only *what it unlocks*.
- Commit counts, file counts, line counts → meaningless to the user.

### Good vs bad examples

**Bad**: *"Refactored path resolution into scripts/lib-paths.sh and added helper functions. Updated 14 files to route through it. Added detect_stack() for phase-2 consumers."*

**Good**: *"Each project now has its own Achilles worker fleet. Run Chanakya in one project, workers in another, and they stay out of each other's way — inboxes, push queues, and logs are all scoped per project. Panes auto-label as `<project>:worker-N` so you can tell at a glance which project a terminal belongs to."*

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
