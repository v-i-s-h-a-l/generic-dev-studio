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
| `scripts/` + pre-commit hooks (`hooks/`, `~/.githooks/`) | Mechanical enforcement (lint gates: `lint-runtime-paths.sh`, `lint-gh-wrapper.sh`, `lint-synthetic-home.sh`, `lint-artifact-cleanup.sh`) |
| GitHub issues (label: `enhancement`, `track:*`, `roadmap`) | Tracked work that hasn't shipped yet |
| Assistant memory (`~/.claude-personal/projects/<hash>/memory/`) | User-specific *context* that genuinely belongs to the user-assistant relationship — preferences, identity hints, prior-session breadcrumbs. **Not workflow rules.** |

**Process rules MUST allow a user-controlled override.** Hard gates that fire without an escape hatch leave the user wedged. The override is the user's lever, not the assistant's — assistants must never bypass on their own initiative. Common patterns: `STUDIO_BYPASS_*=1` env vars, `--bypass-*` flags, explicit `git commit --no-verify` documented as an emergency lever.

Host auto-resolution follows the same rule. `STUDIO_BYPASS_AUTO_HOST_ELIGIBILITY=1`
is the emergency/debug lever for `studio-chain-runner.sh` auto host selection:
it skips the eligibility smoke and uses the first profile in resolver order
as-is, with loud stderr and run-state recording. `STUDIO_HOST_PROFILE_FILE=<path>`
points the resolver at a non-default profile file instead of
`_shared/host-profiles/default.yaml`; pair it with
`STUDIO_AUTO_HOST_ORDER=<csv>` only when intentionally testing or recovering a
specific host order. These are user-controlled levers, not assistant shortcuts.

Durable-state path resolution follows the same rule. `scripts/lint-runtime-paths.sh`
blocks raw `$HOME/.dev-studio/...`, `~/.dev-studio/...`, and
`${HOME}/.dev-studio/...` formulas in `scripts/*.sh`, `core/**/*.sh`, and
`hooks/*` outside the resolver layer (`scripts/lib-paths.sh`,
`scripts/lib-studio-context.sh`); production code must call resolver helpers
(`project_runtime_dir`, `project_state_dir`, `runtime_global_dir`) or the
`STUDIO_CONTEXT_STUDIO_HOME` envelope. `STUDIO_BYPASS_RUNTIME_PATH_LINT=1` is
the emergency/debug lever for `studio-chain-runner.sh` and the pre-commit
gate; it emits a stderr audit line when set. Per-line carve-outs use
`# lint-runtime-paths:allow next-line — <reason>`. The bypass and the
annotation are user-controlled; assistants must not use either silently.

**How to apply:** when the user says "remember X" / "from now on do Y" / "always do Z", first ask: is X a fact about *the user* (preference, identity, context) or a *workflow rule*? If workflow, encode it in the relevant repo file above and offer to add a hook or script when mechanical enforcement is the right shape. If pure user context, then memory is fine. When in doubt, default to repo — repo travels, memory doesn't.

## Worktree protocol (hard rule — no exceptions)

**Never edit the main checkout of this repo directly.** Every session that writes to `generic-dev-studio` must work in a dedicated `git worktree`:

```bash
git fetch origin
git worktree add -b <feature-branch> /tmp/studio-<slug> origin/main
# ... do all work + commits here ...
git push -u origin <feature-branch>
# open a PR and merge via GitHub; never push directly to main
git worktree remove /tmp/studio-<slug>     # clean up when done
```

**Why this is a hard rule:** parallel Claude Code sessions share the same process user and filesystem. When two sessions run in the main checkout simultaneously, one session's `git add` or `git reset` can pick up the other session's unstaged edits — producing accidental co-mingling in commits and making post-hoc untangling expensive or impossible (especially when origin has already advanced). Worktree isolation eliminates the problem at the source: only one session owns a given tree, no shared index, no cross-session bleed.

**Local `main` is a mirror, not a work branch.** Do not commit, merge, rebase,
or cherry-pick onto local `main`. Local `main` should only be fast-forwarded or
reset to `origin/main` after remote PR merges. If local `main` diverges, first
preserve any unique commit on a backup branch, then realign `main` to
`origin/main` with explicit user approval before any destructive reset. The
pre-commit hook blocks base-branch commits unless the user explicitly sets
`STUDIO_BYPASS_MAIN_COMMIT_GUARD=1`.

**This replaces the pathspec rule** (`git commit -- <paths>`). The pathspec approach was a workaround for shared-tree chaos; worktree isolation removes the chaos. The pathspec rule (REVIEW.md) is retired.

**Achilles already follows this** — `scripts/task-worktree-setup.sh` creates per-task worktrees. This rule extends the same discipline to interactive (Chanakya / studio) sessions.

**Worktree lifecycle for interactive sessions:** create before the first write; push/merge after the session's logical unit of work is done; remove immediately after. If the session ends without writing anything, the worktree cleanup is a no-op.

**Worktree marker + 3-layer cleanup.** Every studio-owned worktree under
`~/.dev-studio/<project>/worktrees/<slug>/` carries a marker file
(`.studio-worktree.json`) written by `scripts/lib-worktree-marker.sh` and
heartbeat-touched on every owning-command turn. Three cleanup layers cover
the failure modes:

1. **On finalize / abort:** the owning command (ingest, plan-chain,
   work-chain, task-worktree-setup) removes its worktree.
2. **On session start:** bootstrap invokes
   `scripts/studio-worktree-gc.sh --reap-stale` so crashed sessions cannot
   accumulate (default TTL 7 days; tune via `--ttl-days` or
   `STUDIO_WORKTREE_GC_TTL_DAYS`).
3. **Disk-budget alarm:** `scripts/studio-worktree-gc.sh --budget-check`
   surfaces a one-line warning when the total worktree footprint crosses
   `STUDIO_WORKTREE_DISK_BUDGET_BYTES` (default 5 GiB) or the count crosses
   `STUDIO_WORKTREE_COUNT_BUDGET` (default 10), and points the user at
   `scripts/manager-cleanup.sh --worktrees`.

User-controlled override: `STUDIO_KEEP_WORKTREE=<slug>[,<slug>...]` exempts
named worktrees from layers 2 and 3. Assistants must not set it on their own
initiative. Schema and gc semantics live in
[`_shared/contracts/worktree-marker.md`](_shared/contracts/worktree-marker.md).

## Commit discipline policy (initial taxonomy + message discipline)

Use this policy for assistant-authored commits in this repository.

### Machine-readable host identity (prefer over parsing `Co-authored-by:`)

Use machine-readable host metadata as the source of truth whenever it is present:

- task start artifact: `.studio/chain-task-start.json` (`host`, `model`, `model_version`, related effort fields when present)
- completion artifact: `.studio/chain-worker-summary.json` (`host`, `model`, `model_version`, related effort fields when present)

Do not infer host identity only from a `Co-authored-by:` footer. If host metadata is not available from tooling, assistant-authored commits should append a `Co-authored-by:` footer for the host identity.

Codex-authored commits should include the official Codex co-author trailer for
GitHub-visible credit in addition to `Studio-Host: codex`:
`Co-authored-by: Codex <noreply@openai.com>`. Do not use invented Codex email
addresses such as `codex@openai.com`.

The primary Git author/committer for studio automation in this repo must be
`v-i-s-h-a-l <vishalsingh2706@gmail.com>`. Host credit such as Codex belongs
in `Studio-Host` and `Co-authored-by` metadata; it must not replace the primary
Git author identity.

### Commit-taxonomy values (initial set)

The initial taxonomy values are:

- `feature`
- `bugfix-shipped`
- `bugfix-wip`
- `regression-fix`
- `refactor`
- `docs`
- `test`
- `chore`
- `release`

`bugfix-shipped` marks shipped code-path bugfixes; `bugfix-wip` marks fixes to unreleased WIP work.

### Commit message discipline

- **Subject:** must start with `<taxonomy>: ` and then state the developer-readable what/why headline.
- **Body:** host-authored commits should use the compact impact schema: `Impact`, `Areas`, `Release-Note`, `Why`, and `Risk`. `Impact` is the one-line net behavior or workflow change; `Areas` is the regression-triage index; `Release-Note` is the brief tester/release bullet source, or `none`; `Why` records the cause, trigger, or intent; `Risk` is `none|low|medium|high` plus a short reason. Add `Details` only when larger, risky, or cross-surface changes need deeper implementation context.
- **Transition compatibility:** legacy hosted commits with `Affected-Areas`, `Problem`, `Solution`, `Changelog`, `Implementation notes`, and `Caveats` still pass lint while existing producers migrate. New host-authored commits should prefer the compact schema.
- **Churn rules:** Commits should be logically grouped for future regression triage. Prefer smaller commits, but the hard requirement is no unrelated behavior, docs, test, or workflow changes in the same commit unless the body explains the shared problem/solution.
- **Branch shape:** feature branches should not contain merge commits. Existing chain integration already enforces this via rebase + fast-forward-only merge paths in `scripts/lib-chain-git.sh`; do not treat this as greenfield.
- **Dependencies:** dependent branches should rebase or retarget rather than feature-to-feature merge.

## Studio router (systematic triggers)

The `dev-studio` router is shipped at `core/v2/skills/dev-studio/` and exposed to Claude Code through the global `/dev-studio` command wrapper. It is the canonical role router for studio-level operations after A10 removed the v1 top-level router surfaces. When any of the phrases below fire, route through `/dev-studio manager ...` unless a more specific canonical role is explicit:

| User intent | Trigger phrases | Dispatch |
|---|---|---|
| Resume in-flight arc / "where were we" | "where were we", "pick up from", "resume", `/resume-plan` | `/dev-studio manager resume-plan` |
| Review a studio-repo diff | "review this", "check this", "any issues", "self-review", `/simplify` *on a studio-repo diff* | Cross-host reviewer wrapper by default plus `REVIEW.md`; `/dev-studio reviewer review` only for conversational triage |
| Draft release notes / evaluate tagging | "what's new", "draft release notes", "should we tag", "release" | `/dev-studio release-manager` plus `RELEASES.md` |
| Context-local capture (project ideas by default; Forge/Studio only when explicitly named) | "add to parking lot", "file a pattern", "capture this for the studio" | `/dev-studio manager ingest` via `scripts/dev-studio-ingest-resolve.sh` |
| Arc-coherence audit (plan ↔ memory ↔ commits drift) | `/studio audit`, "audit the arc", "check plan drift" — also auto-runs silently on SessionStart | `/dev-studio manager audit` |
| Pre-work guard (already-shipped / already-tried / already-in-backlog) | `/studio guard <topic>`, "has this been done?", "are we repeating work?" | `/dev-studio manager guard` |
| Add a skill from a git URL | `/studio add <url>`, "add this skill", "install this skill", "vendor this" | `/dev-studio manager add` |
| Sync skills to all hosts | `/studio sync`, "sync skills", "refresh host skills" | `/dev-studio host-adapter sync` |

**Do not dispatch through studio for user-project task work.** Task-level intents (implement X, fix bug Y, review Turnip diff) route to the corresponding `/dev-studio worker`, `/dev-studio reviewer`, or project-specific workflow. The studio router is deliberately scoped to operations that concern the studio itself or cut across agents.

Tier 2 modes (`backlog`, `scaffold`) are not shipped today; if a user intent suggests one, note the gap and route to the closest Tier 1 mode.

The rulebook sections below (**Reviews**, **Releases**, **Docs sync**, **Backlog**) remain authoritative for the *content* of each workflow — the v2 router is just the dispatch surface.

## Reviews

When the user asks to review a diff (any phrasing — "review", "self-review", "check this", "any issues", or invoking `/simplify`), **read `REVIEW.md` at the repo root first** and walk its rules against the diff. Auto-fix the `block + auto-fix` tier silently; surface `ask` tier before changing; note `warn` tier either way.

Do not wait for the user to name REVIEW.md. The file is authoritative for this repo.

**Default to cross-host review.** For any non-trivial review target with a PR,
diff, plan, outcome, or worker/perf artifact, invoke the smoke-gated
cross-host reviewer wrapper rather than only switching the current session into
`/dev-studio reviewer review`. Use `scripts/pr-headless-review.sh` for PRs,
`scripts/phase-review.sh` for plan/outcome artifacts, and
`scripts/task-invoke-argus.sh` for worker task diffs. The inline reviewer role
is for lightweight conversational triage, explaining a wrapper verdict, or
cases where no reviewable artifact exists yet. If the user asks for review from
inside an existing worker or perf session, create or name the review artifact
and run the wrapper unless they explicitly ask for inline-only feedback.

Skip review for single-line doc fixes. Trigger it for: any `scripts/*.sh` change, any `SKILL.md` change, any `_shared/*` change, or diffs >100 lines.

**Walk REVIEW.md *before* committing on a trigger, not after.** Findings go in chat (ask-tier) and in the commit message (all tiers noted). Retroactive reviews are a failure mode — the rule file exists to shape the commit, not audit it afterward.

## Releases

When the user asks about tagging, releasing, release notes, or "what's new" — **read `RELEASES.md` at the repo root first** and follow its template and tone rules. Don't draft release notes without consulting it.

Also, proactively: after landing commits on `main`, evaluate whether the repo has crossed a release-worthy threshold (see `RELEASES.md` → "When to tag"). If yes, surface one sentence suggesting a tag. Don't auto-tag.

When a release ships, update the **Mermaid timeline + "Story so far"** section near the top of `README.md`: add the new release line under the appropriate timeline year, prepend a one-paragraph summary to "Story so far", and remove any "Coming next" / "Long term" themes that the release just delivered. Keep the bullet style outcome-first (same rules as RELEASES.md).

## Docs sync (auto-apply)

Whenever a change adds, removes, or renames a user-visible sub-command, flag, session mode, or any `scripts/*.sh` entry point — **sync the active doc surfaces in the same change, without asking**:

1. `README.md` — TL;DR code block + the relevant `# comment` roster under "What's in the Repo".
2. `core/v2/skills/dev-studio/SKILL.md` / `routing.yaml` — if the router surface changes.
3. Any dedicated docs page that exists for the touched surface.

After updating HTML, open it in Safari once and print the URL. Skip the open step if the diff was doc-only wording or no active HTML doc exists for the touched surface.

Pure rule/doc edits (REVIEW.md, RELEASES.md, CLAUDE.md, THEMES.md, ARCHITECTURE.md) do **not** trigger this — they have no user-facing command surface.

### Layer-separation rule (no cross-pollution)

The v2 role layer (`core/v2/skills/dev-studio/`, `core/v2/roles/`, `core/v2/handoffs/`) and any project-specific task workflow docs are separate user-facing surfaces. Keep their reference content disjoint:

- **Never** duplicate `/dev-studio*` role tables into unrelated project docs. And vice versa — do not copy project-specific task workflow tables into the v2 role router.
- **Do** use one-line scope pointers when the user might mis-route. A pointer prevents lost intent; it is not a copied command table.

**Why:** cards grow out of sync, command enum drift introduces broken references, and users who land on one page expect the commands listed there to actually route through that layer. Mixing surfaces makes every future dispatch-table edit a multi-file coordination problem it doesn't need to be.

This rule applies retroactively: when touching any doc surface, if existing cross-layer cards are present, strip them in the same commit.

## GitHub CLI home normalization (hard rule)

Assistant-initiated GitHub CLI calls in this repo MUST go through `scripts/studio-gh.sh ...`, not raw `gh ...`. Codex and other hosts can launch with synthetic `HOME` values; `scripts/studio-gh.sh` sources `scripts/lib-studio-context.sh` and runs `gh` with `HOME` set from the context-backed `github_home`. Inside scripts, migrated GitHub/auth surfaces should source `scripts/lib-studio-context.sh` and run `gh` or credential-probing `git` under `github_home`; legacy call sites use `with_login_home_for_github` only until their context migration lands.

User-controlled override for intentional isolation tests: `STUDIO_BYPASS_PARENT_HOME_FLIP=1`. Assistants must not set it to bypass a failing GitHub operation.

The wrapper requirement is mechanically enforced by `scripts/lint-gh-wrapper.sh`,
which blocks raw `gh ...` invocations in `scripts/*.sh`, `core/**/*.sh`, and
`hooks/*` outside the wrapper layer (`scripts/studio-gh.sh`,
`scripts/lib-studio-context.sh`). Approved patterns: calls routed through
`scripts/studio-gh.sh`, the `with_login_home_for_github` helper, or the
`gh_api_json` helper. `STUDIO_BYPASS_GH_WRAPPER_LINT=1` is the
emergency/debug lever for `scripts/lint-gh-wrapper.sh` and the pre-commit
gate; it emits a stderr audit line when set. Per-line carve-outs use
`# lint-gh-wrapper:allow next-line — <reason>`. Pre-existing call sites are
captured in `scripts/lint-gh-wrapper-allowlist.txt` and tracked under #710
Phase E for migration; the bypass and the annotation are user-controlled and
must not be used silently by an assistant.

Synthetic-home detection follows the same rule. Production scripts must not
hand-roll `case "$HOME"`, `[ "$HOME" = ... ]`, or inline `*/.codex-homes/*`
pattern matches; instead, call `studio_home_is_synthetic` (defined in
`scripts/lib-paths.sh`) or the `_studio_context_login_home` helper from
`scripts/lib-studio-context.sh`. `scripts/lint-synthetic-home.sh` blocks new
ad-hoc synthetic-home special casing in `scripts/*.sh`, `core/**/*.sh`, and
`hooks/*` outside the resolver layer (`scripts/lib-studio-context.sh`,
`scripts/lib-paths.sh`). Approved patterns: lines that call
`studio_home_is_synthetic` or `_studio_context_login_home` on the same (or
previous) line. `STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1` is the emergency/debug
lever for `scripts/lint-synthetic-home.sh` and the pre-commit gate; it emits
a stderr audit line when set. Per-line carve-outs use
`# lint-synthetic-home:allow next-line — <reason>`. Pre-existing call sites
are captured in `scripts/lint-synthetic-home-allowlist.txt` and tracked under
#710 Phase E for migration; the bypass and the annotation are user-controlled
and must not be used silently by an assistant.

## Artifact cleanup (hard rule)

Studio shell-script workflows MUST clean their own filesystem state on terminal
exit (success and failure). Artifact classes covered: Xcode DerivedData
(default + custom `-derivedDataPath`), git worktrees, `~/.dev-studio/<project>/**`
ephemeral scratch, `/tmp` and `mktemp` directories, booted simulator devices
(`xcrun simctl boot`), xcresult bundles, archives, and IPAs. Existing janitor
scripts (`studio-ios-artifact-janitor.sh`, `node-janitor.sh`,
`fleet-cleanup.sh`, `sweep-janitor.sh`) remain as a periodic safety net;
primary enforcement lives in per-workflow EXIT traps registered through the
shared primitive.

The shared primitive is `scripts/lib-artifact-cleanup.sh` (`register_artifact
<kind> <path> [--keep-on-handoff]` plus EXIT-trap `finalize_artifacts`). It
honors `STUDIO_KEEP_ARTIFACTS=1` as a full-retain user override and stamps
ownership/TTL metadata under a registry directory derived through
`project_state_dir` from `scripts/lib-paths.sh` (no raw `$HOME/.dev-studio/...`
formulas).

The wrapper requirement is mechanically enforced by
`scripts/lint-artifact-cleanup.sh`, which blocks new commits in `scripts/*.sh`,
`core/**/*.sh`, and `hooks/*` that call `xcodebuild`, `-derivedDataPath`,
`git worktree add`, or `mktemp -d` without (a) `register_artifact` on the
same/adjacent line, (b) routing through an approved wrapper (the existing
janitors plus `scripts/lib-artifact-cleanup.sh` itself), or (c) per-line
carve-out `# lint-artifact-cleanup:allow next-line — <reason>`.
`STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1` is the emergency/debug lever for the
pre-commit gate; it emits a stderr audit line when set. Pre-existing call
sites are captured in `scripts/lint-artifact-cleanup-allowlist.txt` and
tracked under #854 (umbrella) for migration; the bypass and the annotation
are user-controlled and must not be used silently by an assistant.

## Backlog

The canonical actionable backlog is the GitHub Projects v2 board documented in
[`PM-SURFACE.md`](PM-SURFACE.md). Use the board for current planning state
(track, phase, size, sibling-review status, and table/board/roadmap views);
GitHub issues remain the durable work items behind each row.

When the user agrees on new work in chat (explicitly: "let's do X", "let's plan Y for later") — **open a GitHub issue** via `scripts/studio-gh-issue-new.sh` with the appropriate label (`phase-2`, `roadmap`, `enhancement`, `bug`, `polish`) so it is also added to the Studio v2 Project board. Use `scripts/studio-gh.sh issue create` only for narrow recovery/debug cases where Project writes are intentionally out of scope. No need to ask permission for items the user has explicitly discussed and agreed to.

When work lands on `main` that closes an issue, close the issue with a one-line note pointing at the commit/PR.

`FORGE-RELIABILITY.md` is archived, not the active-track index. Do not update its historical status rows for routine issue drift. If a new safety-floor regression reopens the Forge lane, create a fresh active planning surface and link the archive instead of appending to it.

When the user asks "what's pending?" / "what's on the list?" / "what's next?" — run `scripts/studio-project-state.sh --status Todo` and surface Project fields (`Status`, `Track`, `Phase`, `Size`, `Sibling host reviewed`) for backlog planning. Use `scripts/studio-gh.sh issue list` only for narrow issue lookups that do not need Project fields. Don't load either list speculatively into context.

When the user asks "what changed on the board?" / "board pulse" / "what's been added or closed?" — run `scripts/studio-project-pulse.sh` (PM-SURFACE.md §Project Pulse Reader). The pulse is manual-only and diffs the current board against the last on-disk snapshot under `~/.dev-studio/<project>/.runtime/state/project-board/`; do not auto-run it on every session, and do not propose wiring it to a cron / LaunchAgent / per-session hook without an explicit cadence decision from the user (#896 non-goal: no noisy notifications).

## Cross-host phase review (hard rule)

For any multi-issue arc (umbrella + sub-issues), substrate redesign, or batch operation that spans more than one logical unit of work, **enforce sibling-host review at every phase boundary**:

1. **Before kicking off a new phase / step / batch:** the host running the work drafts a plan; the sibling host reviews headlessly; iterate until the review returns clean ("nothing fatal").
2. **After completing a phase:** the host that ran the work synthesizes the outcome (changes made, artifacts touched, verification evidence); the sibling host reviews the outcome for drift, scope creep, or missed acceptance criteria.

**Headless review command:**

Use the smoke-gated reviewer wrapper; do **not** hand-compose raw `claude -p`
or `codex exec` commands for phase reviews. Raw commands bypass reviewer auth
root selection, no-secret env scrubbing, MCP isolation, and failure-detail
normalization.

```bash
scripts/phase-review.sh --review-host claude-reviewer --kind plan --input phase-plan.md --output ~/.dev-studio/generic-dev-studio/analysis/<date>-<phase>-plan-review.md
scripts/phase-review.sh --review-host codex-reviewer --kind outcome --input phase-outcome.md --output ~/.dev-studio/generic-dev-studio/analysis/<date>-<phase>-outcome-review.md
```

Pick the sibling reviewer explicitly (`claude-reviewer` when primary is Codex,
`codex-reviewer` when primary is Claude Code). The wrapper runs
`scripts/pr-reviewer-eligibility.sh` first. If the requested reviewer fails
eligibility, execution, timeout, or verdict parsing, the wrapper tries another
cross-host reviewer profile first.

**Degraded reviewer continuity:** when no cross-host reviewer returns usable
output, `scripts/phase-review.sh` may fall back to the parent host's reviewer
profile for intermediate phase gates. This keeps long chains from wedging on a
reviewer outage, but it is not equivalent to sibling-host review:

- The wrapper must emit `PHASE_REVIEW_DEGRADED=1`,
  `PHASE_REVIEW_CROSS_HOST_SATISFIED=false`, and
  `PHASE_REVIEW_NEXT_CROSS_HOST_RETRY=next_boundary`.
- The chain runner may continue only when the degraded reviewer still returns a
  clean verdict.
- The next independent phase/outcome/PR boundary must retry cross-host review
  unless a recorded cooldown says the sibling host is still unavailable.
- Final PR review remains stricter; same-host PR fallback still requires
  explicit user approval through the PR review wrapper.

Disable degraded phase continuity with
`STUDIO_DISABLE_PHASE_REVIEW_DEGRADED_SAME_HOST=1` when the phase must fail
closed instead.

**Field-agent review setup rule:** this same primitive applies when v2 field
agents add cross-host **review** to worker, planner/architect, qa-engineer,
flow-tester, release-manager, or perf workflows. Do not embed raw review-host
CLI spawns (`claude -p`, `codex exec`, etc.) in worker/architect mode packs,
briefs, manifests, or issue acceptance criteria. Route review through the
smoke-gated reviewer profile wrapper (`scripts/phase-review.sh` today) or a v2
successor that preserves the same contract: auth-home selection, no-secret env
scrubbing, MCP isolation, sandbox-readable payload handoff, and failure-detail
surfacing stay centralized. User-controlled override for emergency/debug-only
cases: `STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1`; the bypass must be mentioned in
the plan/outcome artifact and must not be used silently by an assistant. See
`hosts/ADAPTER-SPEC.md` §PR reviewer profiles for the adapter-side contract.

**Required content of phase-plan.md:**

- Goal of the phase
- Scope (in / out)
- Specific changes to be made (files, issues, body edits, closures)
- Acceptance criteria
- Push-backs against any prior review (if applicable)
- Explicit ask: "what's still wrong / missing?"

**Required content of phase-outcome.md:**

- What was actually changed
- Diff summary or list of touched artifacts
- Verification evidence (commands run, results)
- Explicit ask: "did the execution match the plan? any drift?"

**Iterate until "nothing fatal."** Do not execute a phase without a clean plan review. Do not move to the next phase without a clean outcome review. A degraded same-host clean verdict may keep the chain moving only under the continuity rule above; it must stay marked as not cross-host-satisfied and must trigger a cross-host retry at the next boundary.

**Archive every review** to `~/.dev-studio/<project>/analysis/<date>-<phase>-<plan|outcome>-review.md` (NEVER `/tmp` — gets wiped per `feedback_codex_sibling_review_pattern.md` lesson).

**When this rule fires:**

- Multi-issue arcs (current example: v2 transition #442-#446)
- Batch closures of ≥3 issues
- Substrate / architecture changes (anything in `core/`, `_shared/`, schema files, mode pack contracts)
- Release substrate changes
- Any work the user labels as a "phase" or "step"

**When this rule does NOT fire (single-pass agent judgment is sufficient):**

- Single-issue refactors
- Bug fixes
- Doc-only changes
- Time-pressured emergency hotfixes (use solo judgment + post-mortem)
- Work fully scoped within one sub-issue's acceptance criteria

**Why:** different model hosts catch different blind spots. Single-pass review misses framing-level errors that emerge under cross-host scrutiny. The v2 plan's three-round codex review (2026-05-02) demonstrated this — silent scope loss through premature closure was caught by codex round-2 and would have shipped otherwise.

**See also:** `feedback_codex_sibling_review_pattern.md` (operational pattern), `~/.dev-studio/generic-dev-studio/PROMPT.md` (per-session bootstrap that surfaces phase boundaries).

## Request shaping (non-negotiable)

Every host session in this repo must help sharpen feature, bug-fix, workflow, and planning requests before implementation or capture. Treat user wording as the starting point, not a fixed spec.

When the user proposes or asks for work:

- Suggest improvements when a clearer scope, better acceptance criteria, safer rollout, or simpler implementation path is visible.
- Redirect the request when it belongs in a different layer, agent, mode, issue, or workflow; explain the routing briefly.
- Surface meaningful edge cases and adjacent use cases before work starts when they could change the implementation, tests, rollout, or user-facing behavior.
- For workflow steps that save tokens, reduce context, add isolation, or add review passes, surface the economics before design is locked: expected token/context benefit, wall-clock cost, frequency, retry cost, and whether the step blocks the human. Token optimization is default only when the wall-clock delta is nominal; >20% latency in common loops is ask-tier, and 2x+ latency requires explicit user approval unless the check is safety-critical and moved to the least frequent safe boundary or made async.
- For issues and briefs, include the refined shape: goal, impact, before/after behavior, acceptance criteria, edge cases, and non-goals when useful.
- Apply the same habit to changes to these instructions: improve the prompt itself, not just transcribe it.

Keep this pragmatic. Do not turn tiny edits into ceremony, do not block urgent fixes on speculative polish, and do not expand scope silently. If an improvement is obvious and low-risk, fold it in; if it changes behavior, cost, priority, or runtime risk, surface it before implementation.

## Parallel chain surfacing

When studio work contains independent chains, tracks, batches, or issue groups,
surface the parallelization option explicitly. The default assistant shape is:
one short "parallel opportunities" line, followed by one command per manual
shell/session when the user is expected to launch work themselves. Name the
independence boundary (different chain names, disjoint issues, separate
worktrees/branches) and keep dependency-ordered work sequential.

Do not auto-spawn user shell sessions. Do not suggest parallelizing across:
unclean phase-gate reviews, dependent phases, shared branch/index mutations,
or work that has not been shaped enough to know its write boundaries. For
studio chains, prefer `/dev-studio manager work-chain <manifest-or-chain>
--only <chain> --dry-run` per shell first, then the matching `/dev-studio
manager work-chain ... --attended --yes` or default manager work-chain command
after the user accepts the shape. Include script equivalents only as secondary
automation/debug paths.

When an attended or ingest session produces a plan work-chain, end with the
next `/dev-studio manager work-chain ...` command the user can run. After each
chain task completes, surface a compact progress recap: previous task, just
completed task, what changed, next task/command, overall progress, and the
current chain direction/goal.

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
