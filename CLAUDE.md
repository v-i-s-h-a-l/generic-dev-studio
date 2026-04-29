# generic-dev-studio

Multi-agent Claude Code orchestration system (Chanakya manager + Achilles worker + Argus reviewer). Per-project runtime under `~/.dev-studio/<project>/`; machine-global resources under `~/.dev-studio/.runtime/`.

## Active architecture refactor (2026-04 onward)

A multi-session refactor is in progress. Before taking any architectural action, read **`ROADMAP.md` §Phase sequence** (where we are, what's next, dependencies) and **`ARCHITECTURE.md` §Design Vision (2026-04-20 synthesis)** (rationale, agent roster, rejected alternatives). Check `~/.claude-personal/projects/<project-hash>/memory/project_*_pending.md` for questions the previous session deferred to this one.

If the user asks "where were we" or similar, invoke `/resume-plan` — it reads the above and reports.

## Where workflow rules live (hard rule — no exceptions)

**Workflow rules and process enforcement live in the repo, not in assistant memory.** The repo travels — clones to other machines, future contributors, different model harnesses. Memory does not. A rule that exists only in one assistant's memory is a rule that vanishes the moment the user clones the repo elsewhere or switches to another model.

| Where the rule belongs | Examples |
|---|---|
| `CLAUDE.md` / `AGENTS.md` (host-routed instructions) | Workflow conventions, enforcement directives, layer-separation rules |
| `REVIEW.md` | Diff-review rules with tier (block / ask / warn) |
| `RELEASES.md` / `THEMES.md` | Release procedure, theme taxonomy |
| `_shared/rules/*.md`, `_shared/standards/*.md` | Cross-agent discipline, lint contracts |
| `scripts/` + pre-commit hooks (`hooks/`, `~/.githooks/`) | Mechanical enforcement |
| GitHub issues (label: `enhancement`, `track:*`, `roadmap`) | Tracked work that hasn't shipped yet |
| Assistant memory (`~/.claude-personal/projects/<hash>/memory/`) | User-specific *context* that genuinely belongs to the user-assistant relationship — preferences, identity hints, prior-session breadcrumbs. **Not workflow rules.** |

**Process rules MUST allow a user-controlled override.** Hard gates that fire without an escape hatch leave the user wedged. The override is the user's lever, not the assistant's — assistants must never bypass on their own initiative. Common patterns: `STUDIO_BYPASS_*=1` env vars, `--bypass-*` flags, explicit `git commit --no-verify` documented as an emergency lever.

**How to apply:** when the user says "remember X" / "from now on do Y" / "always do Z", first ask: is X a fact about *the user* (preference, identity, context) or a *workflow rule*? If workflow, encode it in the relevant repo file above and offer to add a hook or script when mechanical enforcement is the right shape. If pure user context, then memory is fine. When in doubt, default to repo — repo travels, memory doesn't.

## Worktree protocol (hard rule — no exceptions)

**Never edit the main checkout of this repo directly.** Every session that writes to `generic-dev-studio` must work in a dedicated `git worktree`:

```bash
git worktree add /tmp/studio-<slug> main   # create isolated tree
# ... do all work + commits here ...
git push origin main                        # or cherry-pick/merge back to main
git worktree remove /tmp/studio-<slug>     # clean up when done
```

**Why this is a hard rule:** parallel Claude Code sessions share the same process user and filesystem. When two sessions run in the main checkout simultaneously, one session's `git add` or `git reset` can pick up the other session's unstaged edits — producing accidental co-mingling in commits and making post-hoc untangling expensive or impossible (especially when origin has already advanced). Worktree isolation eliminates the problem at the source: only one session owns a given tree, no shared index, no cross-session bleed.

**This replaces the pathspec rule** (`git commit -- <paths>`). The pathspec approach was a workaround for shared-tree chaos; worktree isolation removes the chaos. The pathspec rule (REVIEW.md) is retired.

**Achilles already follows this** — `scripts/task-worktree-setup.sh` creates per-task worktrees. This rule extends the same discipline to interactive (Chanakya / studio) sessions.

**Worktree lifecycle for interactive sessions:** create before the first write; push/merge after the session's logical unit of work is done; remove immediately after. If the session ends without writing anything, the worktree cleanup is a no-op.

## Studio router (systematic triggers)

The `studio` skill is a **project-scoped vendor skill** shipped at `.claude/skills/studio/`. It is the cross-agent router for studio-level operations. Its Tier 1 modes cover the six most common studio-scoped user intents. When any of the phrases below fire, dispatch into the matching mode (slash commands are thin wrappers — the mode pack is authoritative):

| User intent | Trigger phrases | Dispatch |
|---|---|---|
| Resume in-flight arc / "where were we" | "where were we", "pick up from", "resume", `/resume-plan` | `.claude/skills/studio/modes/resume-plan.md` |
| Review a studio-repo diff | "review this", "check this", "any issues", "self-review", `/simplify` *on a studio-repo diff* | `.claude/skills/studio/modes/review.md` |
| Draft release notes / evaluate tagging | "what's new", "draft release notes", "should we tag", "release" | `.claude/skills/studio/modes/release.md` |
| Studio-level capture (patterns, analysis, parking-lot, rule tweaks) | "add to parking lot", "file a pattern", "capture this for the studio" | `.claude/skills/studio/modes/ingest.md` |
| Arc-coherence audit (plan ↔ memory ↔ commits drift) | `/studio audit`, "audit the arc", "check plan drift" — also auto-runs silently on SessionStart | `.claude/skills/studio/modes/audit.md` |
| Pre-work guard (already-shipped / already-tried / already-in-backlog) | `/studio guard <topic>`, "has this been done?", "are we repeating work?" | `.claude/skills/studio/modes/guard.md` |
| Add a skill from a git URL | `/studio add <url>`, "add this skill", "install this skill", "vendor this" | `.claude/skills/studio/modes/add.md` |
| Sync skills to all hosts | `/studio sync`, "sync skills", "refresh host skills" | `.claude/skills/studio/modes/sync.md` |

**Do not dispatch through studio for user-project task work.** Task-level intents (implement X, fix bug Y, review Turnip diff) route to `/chanakya`, `/achilles`, `/argus` directly. The studio router is deliberately scoped to operations that concern the studio itself or cut across agents.

Tier 2 modes (`backlog`, `scaffold`) are not shipped today; if a user intent suggests one, note the gap and route to the closest Tier 1 mode.

The rulebook sections below (**Reviews**, **Releases**, **Docs sync**, **Backlog**) remain authoritative for the *content* of each mode — the studio router is just the dispatch surface.

## Reviews

When the user asks to review a diff (any phrasing — "review", "self-review", "check this", "any issues", or invoking `/simplify`), **read `REVIEW.md` at the repo root first** and walk its rules against the diff. Auto-fix the `block + auto-fix` tier silently; surface `ask` tier before changing; note `warn` tier either way.

Do not wait for the user to name REVIEW.md. The file is authoritative for this repo.

Skip review for single-line doc fixes. Trigger it for: any `scripts/*.sh` change, any `SKILL.md` change, any `_shared/*` change, or diffs >100 lines.

**Walk REVIEW.md *before* committing on a trigger, not after.** Findings go in chat (ask-tier) and in the commit message (all tiers noted). Retroactive reviews are a failure mode — the rule file exists to shape the commit, not audit it afterward.

## Releases

When the user asks about tagging, releasing, release notes, or "what's new" — **read `RELEASES.md` at the repo root first** and follow its template and tone rules. Don't draft release notes without consulting it.

Also, proactively: after landing commits on `main`, evaluate whether the repo has crossed a release-worthy threshold (see `RELEASES.md` → "When to tag"). If yes, surface one sentence suggesting a tag. Don't auto-tag.

When a release ships, update the **Mermaid timeline + "Story so far"** section near the top of `README.md`: add the new release line under the appropriate timeline year, prepend a one-paragraph summary to "Story so far", and remove any "Coming next" / "Long term" themes that the release just delivered. Keep the bullet style outcome-first (same rules as RELEASES.md).

## Docs sync (auto-apply)

Whenever a change adds, removes, or renames a user-visible sub-command, flag, or session mode across `chanakya/SKILL.md`, `achilles/SKILL.md`, `argus/SKILL.md`, or any `scripts/*.sh` entry point — **sync the three doc surfaces in the same change, without asking**:

1. `chanakya/docs.html` — add/update the matching card in Quick Reference, Composites, or Fleet sections.
2. `README.md` — TL;DR code block + the relevant `# comment` roster under "What's in the Repo".
3. `chanakya/README.md` — if the long-form walkthrough touches the affected mode.

After updating HTML, open it in Safari once (`open -a Safari "file://…/chanakya/docs.html"`) and print the URL. No need to ask. Skip the open step if the diff was doc-only wording (no new cards).

Pure rule/doc edits (REVIEW.md, RELEASES.md, CLAUDE.md, THEMES.md, ARCHITECTURE.md) do **not** trigger this — they have no user-facing command surface.

### Layer-separation rule (no cross-pollution)

The **agent layer** (`chanakya/`, `achilles/`, `argus/` — their SKILL.md, docs.html, README, mode packs) and the **studio layer** (`.claude/skills/studio/` — its SKILL.md, docs.html, mode packs) are separate user-facing surfaces. Keep their reference content disjoint:

- **Never** add `/studio*` command reference cards or sub-command tables to chanakya/achilles/argus docs, SKILL.md, or mode packs. And vice versa — **never** add `/chanakya*`, `/achilles*`, `/argus*` reference cards to studio docs/SKILL/modes.
- **Do** use one-line *scope pointers* ("for X, route to /other-layer") when the user might mis-route — these prevent lost intent, they don't duplicate surface. Example that's fine: studio/SKILL.md says "task-level work goes to /chanakya etc." A pointer, not a table.
- Cross-links between the two docs.html pages are fine (`<a href="../../../chanakya/docs.html">`). Duplicating the *contents* of those pages is not.

**Why:** cards grow out of sync, command enum drift introduces broken references, and users who land on one page expect the commands listed there to actually route through that layer. Mixing surfaces makes every future dispatch-table edit a multi-file coordination problem it doesn't need to be.

This rule applies retroactively: when touching any doc surface, if existing cross-layer cards are present, strip them in the same commit.

## Backlog

When the user agrees on new work in chat (explicitly: "let's do X", "let's plan Y for later") — **open a GitHub issue** for it via `gh issue create` with the appropriate label (`phase-2`, `roadmap`, `enhancement`, `bug`, `polish`). No need to ask permission for items the user has explicitly discussed and agreed to.

When work lands on `main` that closes an issue, close the issue with a one-line note pointing at the commit/PR.

If the issue appears in `FORGE-RELIABILITY.md`, update that lookup's `Status` in the same PR or immediate cleanup commit. The file is the curated active-track index; do not let it drift from GitHub.

When the user asks "what's pending?" / "what's on the list?" / "what's next?" — run `gh issue list` and surface; don't load the issue list speculatively into context.

## Request shaping (non-negotiable)

Every host session in this repo must help sharpen feature, bug-fix, workflow, and planning requests before implementation or capture. Treat user wording as the starting point, not a fixed spec.

When the user proposes or asks for work:

- Suggest improvements when a clearer scope, better acceptance criteria, safer rollout, or simpler implementation path is visible.
- Redirect the request when it belongs in a different layer, agent, mode, issue, or workflow; explain the routing briefly.
- Surface meaningful edge cases and adjacent use cases before work starts when they could change the implementation, tests, rollout, or user-facing behavior.
- For issues and briefs, include the refined shape: goal, impact, before/after behavior, acceptance criteria, edge cases, and non-goals when useful.
- Apply the same habit to changes to these instructions: improve the prompt itself, not just transcribe it.

Keep this pragmatic. Do not turn tiny edits into ceremony, do not block urgent fixes on speculative polish, and do not expand scope silently. If an improvement is obvious and low-risk, fold it in; if it changes behavior, cost, priority, or runtime risk, surface it before implementation.

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

All runtime writes go under `~/.dev-studio/**`. Scripts resolve paths via `scripts/lib-paths.sh` — never hardcode. See `_shared/primitives/file-locations.md` for canonical roots.
