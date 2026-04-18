# generic-dev-studio

Multi-agent Claude Code orchestration system (Chanakya manager + Achilles worker + Argus reviewer). Per-project runtime under `~/.dev-studio/<project>/`; machine-global resources under `~/.dev-studio/.runtime/`.

## Reviews

When the user asks to review a diff (any phrasing — "review", "self-review", "check this", "any issues", or invoking `/simplify`), **read `REVIEW.md` at the repo root first** and walk its rules against the diff. Auto-fix the `block + auto-fix` tier silently; surface `ask` tier before changing; note `warn` tier either way.

Do not wait for the user to name REVIEW.md. The file is authoritative for this repo.

Skip review for single-line doc fixes. Trigger it for: any `scripts/*.sh` change, any `SKILL.md` change, any `_shared/*` change, or diffs >100 lines.

## Releases

When the user asks about tagging, releasing, release notes, or "what's new" — **read `RELEASES.md` at the repo root first** and follow its template and tone rules. Don't draft release notes without consulting it.

Also, proactively: after landing commits on `main`, evaluate whether the repo has crossed a release-worthy threshold (see `RELEASES.md` → "When to tag"). If yes, surface one sentence suggesting a tag. Don't auto-tag.

When a release ships, update the **Mermaid timeline + "Story so far"** section near the top of `README.md`: add the new release line under the appropriate timeline year, prepend a one-paragraph summary to "Story so far", and remove any "Coming next" / "Long term" themes that the release just delivered. Keep the bullet style outcome-first (same rules as RELEASES.md).

## Backlog

When the user agrees on new work in chat (explicitly: "let's do X", "let's plan Y for later") — **open a GitHub issue** for it via `gh issue create` with the appropriate label (`phase-2`, `roadmap`, `enhancement`, `bug`, `polish`). No need to ask permission for items the user has explicitly discussed and agreed to.

When work lands on `main` that closes an issue, close the issue with a one-line note pointing at the commit/PR.

When the user asks "what's pending?" / "what's on the list?" / "what's next?" — run `gh issue list` and surface; don't load the issue list speculatively into context.

## Auto-apply tiers (reduce user touchpoints)

The studio's own rules and conventions are auto-improvable. Some changes apply silently; some require a quick OK. Default to action; ask only when there's real ambiguity.

**Auto-apply tier (apply, commit, brief in next session):**
- Rule wording tweaks in `REVIEW.md`, `RELEASES.md`, `CLAUDE.md`, `THEMES.md`
- Threshold adjustments backed by data (build-debt warn 6→8, Argus diff cap 500→400)
- Brief-template additions when patterns show repeated clarification asks
- Skill-prose trimming when an SKILL.md section never gets used (token savings)
- Comment improvements, dead-code removal, README clarifications
- New issue creation when work is explicitly discussed and agreed
- Theme label assignment on existing/new issues
- Updating README's roadmap timeline + Story so far on releases

**Ask-first tier (always require user OK):**
- Changing how agents hand off (Chanakya → Achilles flow)
- Removing or renaming rules / sub-commands / event types
- Anything that changes what blocks or what runs in the user's actual project at runtime
- Permission scope, secrets, auth changes
- Any breaking change (per RELEASES.md MAJOR rules)
- Deleting issues or releases

**Adaptive trust.** Track which auto-applies get reverted by the user. If a class of change has zero reverts after 5 applications, the auto-apply criteria can loosen for that class. If something gets reverted, that class tightens. The system learns what the user actually wants.

**Hard stop.** Auto-apply never touches the user's project's runtime behavior — only the studio's internal rules. Their project is sacred; the studio's conventions are negotiable.

## Briefing convention

Brief the user on cumulative work or non-obvious decisions. Stay silent on trivial changes (typo, comment, formatting).

- **Brief**: 3+ small auto-applied changes batched, OR 1 medium change, OR a behavioral inference acted on, OR a tradeoff made.
- **Don't brief**: routine commits, label additions, doc-only fixes that match an explicit request, mechanical refactors.
- **Format**: 2–4 lines max in the next session. "Did X, Y, Z. Reason: …. Revert any of it with Q if wrong."

## Analysis sessions and privacy

Analysis of how the studio is being used in real projects runs **from this repo (generic-dev-studio)**, not from the project being analyzed. Reasons: right gh account by default, no auth juggling across personal/work identities, no bleed of tool-internal concerns into work sessions. Cross-repo reads are fine — `~/.dev-studio/**` is allowlisted from any session.

**Output split (load-bearing):**

| Output | Location | Visibility |
|---|---|---|
| Detailed analysis report | `~/.dev-studio/<project>/analysis/<date>.md` | Private — never committed anywhere |
| Distilled patterns + proposals | GitHub issues on generic-dev-studio | Public |
| Code/doc improvements | Commits to this repo | Public |

**Privacy rule for any public output (issues, commits, PR descriptions):**

Strip everything project-specific before publishing. Specifically: task IDs, feedback-record IDs, debrief/review text quoted verbatim, Slack channel names, @mentions, commit messages or branch names from the work project, file paths revealing proprietary architecture, build numbers, TestFlight versions, feature names ("the new crop tool"), anyone's name, performance/velocity numbers.

Public issues describe **abstract patterns** (e.g. "Argus's secrets-in-diff rule triggers on test fixtures ~30% of the time — false positive; consider exempting `*Tests.swift`"), not specific incidents. Detailed citations go into the private analysis report only.

**Self-check before publishing:** *if this text were posted to a competitor's Slack, would anything embarrassing or proprietary leak?* If yes, rewrite as anonymous pattern. If still leaky, keep it private.

## Paths

All runtime writes go under `~/.dev-studio/**`. Scripts resolve paths via `scripts/lib-paths.sh` — never hardcode. See `_shared/file-locations.md` for canonical roots.
