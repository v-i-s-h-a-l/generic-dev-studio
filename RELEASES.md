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

Semver (`MAJOR.MINOR.PATCH`), starting at `v0.1` when the first tag lands.

- `v0.x` → pre-stable; minor bumps can include breaking changes *if the What's new section flags them*.
- `v1.0` → first stable release. After that, breaking changes bump `MAJOR`; new capabilities bump `MINOR`; fixes bump `PATCH`.

Don't fight the versioning. If in doubt, bump `MINOR`.

## Mechanics

GitHub release flow (once ready):

1. Ensure `main` is green (scripts pass `bash -n`, smoke tests pass, REVIEW.md rules satisfied).
2. Draft the release notes in this template — work on a scratch file first, not directly in the tag annotation.
3. Tag: `git tag -a vX.Y.Z -m "<title from notes>"` with an annotated tag, not a lightweight one.
4. Push: `git push origin vX.Y.Z`.
5. `gh release create vX.Y.Z --notes-file <scratch-file>` — publishes to GitHub with the markdown rendered.
6. Append the same notes to `CHANGELOG.md` (top of file, newest first).

Never tag without notes. Never tag a commit that's not on `main`. Never force-push or delete a published tag.
