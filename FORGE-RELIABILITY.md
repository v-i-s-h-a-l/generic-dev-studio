# Forge Reliability Lookup

Curated lookup for the current Forge reliability path. Use this before broad `gh issue list` searches.

This file is intentionally small and hand-maintained. It records the issues we have agreed are relevant to the reliability freeze or the first capability arc after it. GitHub remains the source of truth for open/closed state; update this file when an issue is closed, reclassified, or replaced.

## Update Rule

- When closing or superseding an issue listed here, update its `Status` in the same PR or follow-up cleanup commit.
- When a new reliability bug is filed, add it to **Safety-Floor Queue** if it can strand work, hide artifacts, bypass review, or make status/analytics lie.
- When a new agent-improvement issue is filed, add it to **Capability-Next Queue** only if it changes how an existing agent reasons, reviews, debugs, routes, or spends tokens.
- Keep **Up Next** at exactly 10 open tasks in priority order. When a new issue is created during planning and belongs in the next 10, insert it immediately and demote the last row.
- Refresh **Up Next** automatically when any of the top 3 rows close; that is the point where the list would otherwise have only 7 live tasks after the completed work is removed.
- Do not add every backlog item. This is a curated control-plane lookup, not a mirror of GitHub Issues.

## Up Next

Curated next 10 for Forge reliability work. This list is the quick lookup; GitHub Issues remains the source of truth for state.

| Rank | Issue | Why Now |
|---:|---|---|
| 1 | [#364](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/364) Analyze collection must be host-agnostic and `.dev-studio`-first | Makes the diagnostic surface trustworthy before we use it to judge blind spots. |
| 2 | [#315](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/315) Ledger bypass suppresses event emission and sweep hooks | Closes direct artifact paths that make downstream hooks silently no-op. |
| 3 | [#314](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/314) Canonical event log reconstruction can hide lifecycle windows | Makes event-log loss bounded and recoverable instead of falsely precise. |
| 4 | [#226](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/226) Inbox sweep observability | Surfaces missing debriefs and handoff anomalies instead of waiting for manual investigation. |
| 5 | [#241](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/241) Review-coverage metric in `/chanakya status` | Turns Argus dark periods into a visible process metric. |
| 6 | [#362](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/362) `push-tf` must preflight GitHub auth before mutating build number | Prevents release workflows from creating partial external state before auth is proven. |
| 7 | [#97](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/97) App Store live version lookup must use app-scoped endpoint | Release/status logic must not depend on a forbidden top-level endpoint. |
| 8 | [#322](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/322) Add provider model catalog and reviewer model policy | Gives reviewer/worker selection a maintained model source instead of hardcoded stale names. |
| 9 | [#323](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/323) Improve Chanakya brief quality | Smaller, measurable briefs improve Achilles output, Argus review, and future test generation. |
| 10 | [#313](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/313) Argus dispatch fails when host registry is missing | Keeps the review gate available from deployed skills layouts. |

## Active Chain: Forge blind-spot closure

Label: `chain/forge-blindspots`

Resolve in this order unless an urgent release fix is explicitly pulled forward:

1. [#364](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/364) — make `/studio analyze` host-agnostic and `.dev-studio`-first.
2. [#315](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/315) — close ledger bypass paths that create artifacts without lifecycle/event hooks.
3. [#314](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/314) — make event-log reconstruction bounded and recoverable.
4. [#226](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/226) — add sweep and handoff observability for missing debriefs and lifecycle anomalies.
5. [#241](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/241) — expose review-coverage windows in status and push surfaces.
6. [#362](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/362) — harden release preflight before build-number mutation.
7. [#97](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/97) — repair live-version lookup through app-scoped ASC APIs.

Chain goal: artifacts and events reconcile cleanly; missing evidence is surfaced as `unknown` or repairable, not silently treated as absent.

## Safety-Floor Queue

These remain eligible during the Forge reliability freeze because they prevent silent bad states, unsafe handoffs, hidden artifacts, or false status.

| Issue | Status | Class | Why It Belongs Here |
|---|---|---|---|
| [#316](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/316) Sweep ingest silently skips lifecycle side effects when debrief facts are present but events are missing | Closed | Reliability bug | Inbox sweep must reconcile canonical debrief facts into queue drain, review-skip, audit, status, and follow-up signals. |
| [#347](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/347) Measure Forge task latency after review-gate enforcement | Closed | Observability | Review-gate slowdown claims must be measured by stage so optimization targets evidence without weakening the safety floor. |
| [#364](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/364) Analyze collection must be host-agnostic and `.dev-studio`-first | Open | Reliability bug | Analysis can falsely report no usable surface when runtime artifacts exist under `.dev-studio` but host-specific memory is missing. |
| [#315](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/315) Ledger bypass with non-canonical task IDs suppresses event emission and sweep hooks | Open | Reliability bug | Direct artifact creation can bypass lib-ledger contracts and make downstream hooks silently no-op. |
| [#314](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/314) Canonical event log reconstruction can hide lifecycle windows from sweeps | Open | Reliability bug | Event-log loss makes sweeps and analytics falsely precise unless gaps are bounded and recoverable. |
| [#313](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/313) Argus dispatch fails when host registry is missing from deployed skills layout | Open | Reliability bug | Review gate availability depends on host registry deployment and deterministic infra-failure handling. |
| [#223](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/223) Achilles ↔ Argus contract hardening | Open | Safety-floor hardening | Tightens review handoff timeouts, base-staleness consistency, and stage payloads. |
| [#224](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/224) Argus → merge gate policy + sibling-merge race | Open | Safety-floor hardening | Closes paths where flagged reviews or sibling merges can pass the merge boundary unsafely. |
| [#240](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/240) Concern→task auto-mint from debrief follow-ups and debt flags | Open | Safety-floor hardening | Prevents `done_with_concerns` and structured follow-ups from being absorbed without tasks. |
| [#226](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/226) Inbox sweep observability | Open | Observability | Handoff anomalies and missing debriefs should emit visible signals before they become stale status drift. |
| [#241](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/241) Review-coverage metric in `/chanakya status` | Open | Observability | Makes review dark periods visible as a metric, not a post-hoc investigation. |
| [#195](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/195) Merged task shown as briefed / missing debrief | Open | Reliability bug | Status can show completed work as pending when debrief emission is missing. |
| [#362](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/362) `push-tf` must preflight GitHub auth before mutating build number | Open | Reliability bug | Release workflows must prove required auth before creating partial external state. |
| [#391](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/391) Claude reviewer runner lacks a dedicated auth/config root | Open | Reliability bug | Headless PR review can look eligible but still fail at runtime when `claude-reviewer` inherits an empty session home. |
| [#97](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/97) App Store live version lookup must use app-scoped endpoint | Open | Reliability bug | Release/status logic must not depend on a forbidden top-level endpoint. |
| [#76](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/76) Audit mode-pack dual-write during Phase 2.6 transition | Open | Reliability bug | Ensures no active prose or writer still mutates retired legacy surfaces. |
| [#318](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/318) PR merge autopilot with headless reviewer gate | Closed | Safety-floor hardening | Makes PR review and merge flow explicit: headless reviewer first, critical blockers stop only that PR, and integration advances only through GitHub PR merge. |
| [#325](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/325) Harden PR autopilot merge method and local cleanup | Closed | Reliability bug | Prevents a successful remote merge from being reported as failed because local cleanup ran from a detached or stale worktree. |

## PR Autopilot Policy

Issue [#318](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/318) defines the current Forge PR path.

- Related issues MAY share one feature or reliability branch when they touch one workflow surface, one user-facing capability, or one safety-floor path. This is the default for coherent slices; it is not a bypass.
- Use single-issue PRs for urgent bugs, risky isolated changes, unrelated ownership, or branches that are becoming hard to review.
- Grouped PR descriptions MUST list every included issue and close each one individually (`Closes #A`, `Closes #B`). `FORGE-RELIABILITY.md` rows keep issue-level status even when implementation lands through a grouped PR.
- Split a grouped branch when the diff crosses unrelated agents, lacks shared tests, exceeds one meaningful reviewer pass, or mixes release urgency with non-urgent cleanup.
- Default routine studio PRs to merge after one headless reviewer gate unless the reviewer reports a critical blocker.
- Critical blockers are narrow: data loss, broken routing, unsafe runtime behavior, permission/auth changes, base-branch bypass, failing required checks, merge conflicts, or repo-rule violations.
- Reviewer sessions MAY auto-fix narrow non-critical findings on the PR branch and MUST summarize those fixes on the PR.
- Reviewer sessions MUST NOT receive GitHub tokens or arbitrary inherited token-bearing user config; the parent studio session owns `gh` comments, suggestions, merge, branch deletion, and fetch/prune cleanup. Codex reviewers get a temporary `HOME` plus only `CODEX_HOME` for model auth.
- Codex review uses a dedicated `codex-reviewer` adapter/profile with `secret_scope: none`; do not flip the normal Codex worker adapter unless the spawn path enforces the same no-secret boundary.
- Routine studio PRs run `scripts/pr-headless-review.sh <pr>`; it selects an eligible no-secret reviewer host, captures the machine-readable verdict, posts the `studio:pr-review-gate` comment, and merges only when non-blocked.
- Parent studio sessions MUST post a machine-readable `studio:pr-review-gate` PR comment before merge; `blocked` stops that PR, while `approved` and `approved_with_fixes` permit merge.
- Merge only through GitHub PR flow; after merge, delete the stale remote branch and refresh local refs with `git fetch --prune`.
- `--method auto` uses rebase for PRs with fewer than 4 commits, including PRs targeting `main`; larger `main` PRs use merge commits, while non-`main` PRs continue to rebase.
- Bypass is not interactive and is not implicit: `pr-merge-finalize.sh` refuses ungated PRs unless passed `--bypass-review --user-approved-bypass <github-url>`, and records that bypass on the PR.

### Group vs Split Heuristics

| Group when | Split when |
|---|---|
| Issues share the same scripts, mode packs, docs, or tests. | Issues touch unrelated agents or ownership surfaces. |
| One review can understand the safety argument end-to-end. | The branch needs multiple independent safety arguments. |
| The branch reduces repeated PR/review latency without weakening gates. | An urgent bug should ship ahead of lower-priority cleanup. |
| Each issue remains traceable in commits, PR body, and status tables. | Issue closure would become ambiguous or buried. |

## Capability-Next Queue

Important agent-capability improvements. Do not start these ahead of open safety-floor bugs unless the user explicitly waives the freeze for a named issue.

| Issue | Status | Agent | Why It Matters |
|---|---|---|---|
| [#203](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/203) Achilles debug mode + bug-fix flow rewrite | Open | Achilles | Adds a bug-fix-specific workflow for localization, failing-test gates, and higher-quality repair loops. |
| [#213](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/213) Achilles SourceKit-LSP symbol localization | Open | Achilles | Improves bug localization from file-level grep to symbol-level Swift resolution. |
| [#257](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/257) Argus change-classifier for selective rule loading | Open | Argus | Reduces review latency and token use by loading only relevant review rules for a diff. |
| [#256](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/256) Achilles brief-summary primitive | Open | Achilles / Chanakya | Adds compact brief slices for cheap reads and dispatch/status decisions. |
| [#65](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/65) Task-level model recommendation system | Closed | Cross-agent | Moves model choice from static agent defaults to task-aware recommendations. |

## Role-Clarity Queue

Useful governance work. It supports agent quality but is lower priority than safety-floor and capability mechanics.

| Issue | Status | Class | Why It Matters |
|---|---|---|---|
| [#199](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/199) Concern emission discipline + scope-expansion budget | Open | Governance | Makes Achilles concerns more deliberate and budgeted instead of a flat catch-all field. |
| [#200](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/200) Argus value-prop clarification | Open | Governance | Prevents Argus from being mistaken for a test runner and disabled as redundant. |
| [#202](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/202) Explicit non-goals in each agent `SKILL.md` | Open | Governance | Prevents scope drift across Chanakya, Achilles, Argus, and studio. |

## Deferred Roadmap

Important, but explicitly after the reliability freeze unless a named waiver is given.

| Issue | Status | Class | Why Deferred |
|---|---|---|---|
| [#141](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/141) Host-agnostic Chanakya v2 | Open | Roadmap | Expands orchestrator portability; not needed to repair current safety-floor bugs. |
| [#38](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/38) Lu Ban architect subagent | Open | Roadmap | New agent capability; deferred until existing control-plane reliability is stable. |
