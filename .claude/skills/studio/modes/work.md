---
name: Studio Work Mode
description: Autonomous issue worker for a parallel track. Claims issues, commits them to the track branch, then opens one final reviewed PR to main with cleanup and summary.
type: mode-pack
schema_version: 1
budget_tokens: 600
reads:
  - TRACKS.md
  - scripts/track-next.sh output
  - chain manifest YAML for `/studio work chain <manifest-or-name>`
  - .claude/skills/studio/modes/summary.md
writes:
  - track branch commits
  - GH issue state (assign + close)
  - track PR
  - chain feature branches
  - per-issue branches/worktrees under /tmp
---

# Mode: Work

Autonomous worker for a named parallel track. Runs a pick → shape → implement → commit → close loop on the track branch, then opens one final PR for the whole track and runs the normal studio PR review/automerge/cleanup path.

## Entry

Triggered by:
- `/studio work <track>` — explicit invocation
- `/studio work chain <manifest-or-name>` — execute one or more chains from a manifest
- `STUDIO_TRACK=<track>` env var at session start (SessionStart hook injects the first directive automatically; subsequent issues loop via this mode)

Without the `work` sub-command, start the host session with `STUDIO_TRACK=<track>` from inside `generic-dev-studio`; the session-start directive enters this mode automatically.

## Chain entry

Use chain mode when the user wants a multi-chain sequence where each chain starts from latest `main`, each issue gets its own branch/worktree/fresh host session, and the chain lands as one reviewed PR before the next chain starts.

Run:

```bash
scripts/studio-chain-runner.sh <manifest-or-name> [--only <chain>] [--host codex|claude-code] [--dry-run] [--yes]
scripts/studio-chain-runner.sh --resume <run_id> [--yes]
```

## Manual parallel shell guidance

When a manifest contains independent chains, tell the user they can open one
shell session per chain and run `--only <chain>` in each. Start with dry-runs
so branch/worktree/PR/review shape is visible before execution:

```bash
# Shell 1
scripts/studio-chain-runner.sh <manifest-or-name> --only <chain-a> --dry-run

# Shell 2
scripts/studio-chain-runner.sh <manifest-or-name> --only <chain-b> --dry-run
```

After the user accepts the dry-run shape, provide the matching non-dry-run
commands. Only suggest this when the chains are dependency-independent and do
not share an integration branch or phase gate. Each chain runner creates its
own worktrees and final reviewed PR; keep dependent chains sequential.

Manifest:

```yaml
schema_version: 1
chains:
  - name: field-telemetry-mvp
    base: main
    branch: feature/field-telemetry-mvp
    host: auto
    issues: [388, 25, 367]
```

The manifest argument may be a file path, or a bare name resolved as `chains/<name>.yaml` and then `chains/<name>.yml`. For example, `/studio work chain workflow-measurement-improvements` resolves to `chains/workflow-measurement-improvements.yaml`.

Chain behavior:

1. Fetch latest `origin/<base>`.
2. Create one chain feature branch/worktree from latest base.
3. Print the resolved execution plan by default: chain order, issue titles/states, branches, worktrees, host policy, risk notes, planned PRs, and the private state path. The runner exits after this plan unless `--yes` / `--no-confirm` is present; `--dry-run` prints the same graph and then non-mutating commands.
4. Persist run state under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/state.json`. Resume a blocked/crashed run with `scripts/studio-chain-runner.sh --resume <run_id> --yes`; completed chains/issues are skipped or re-integrated from their recorded branches.
5. Validate the graph before live execution: issue IDs must be unique across chains, issues must be open unless `--allow-closed-issues` is present, branch refs must be safe and non-colliding, GitHub auth must work, the reviewer host must be available, and base refs must be reachable.
6. Size the fresh-session pool from healthy registered `xcodebuild` offload nodes: local-only stays at 1; N healthy offload nodes yields N+1 sessions, capped by available RAM. Override only for emergencies with `STUDIO_CHAIN_WORKER_POOL`, or clamp with `STUDIO_CHAIN_MAX_WORKERS`.
7. For each issue, create `<chain-branch>-issue-<N>` in a separate `/tmp/studio-chain-runner/...` worktree. Issue execution is sequential within a chain; `--parallel-chains <n|auto|1>` records the requested chain scheduling policy, while the current runner serializes chain PR/review/issue-closure mutation unless a later scheduler proves safe concurrency.
8. Spawn a fresh host session (`codex exec` by default for `host: auto`, or the manifest/flag host) with a scoped prompt to implement exactly that issue and commit on the issue branch. The prompt includes `run_id`, `chain_run_id`, `issue_run_id`, and the required `.studio/chain-worker-summary.json` path.
9. Validate and ingest each worker summary. If it is missing, emit a telemetry gap rather than treating absent model/token/build data as zero.
10. Rebase completed issue branches onto the chain branch and fast-forward them into the chain branch in manifest order.
11. Keep the issue open while the chain branch is still only a feature branch.
12. After the last issue, rebase the chain branch on latest base, open a PR, and run `scripts/pr-headless-review.sh <pr> --method auto`.
13. If the reviewer blocks, STOP with the PR and worktree intact for repair. If non-blocked, the normal autopilot merge path runs.
14. Close/comment the chain issues after the PR path succeeds.
15. Write a final private report under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/report.md`, then fetch/prune locally and remove the chain/issue worktrees after merge.

Telemetry:

- Runner-owned lifecycle events: `chain_run_started`, `chain_started`, `chain_issue_started`, `chain_issue_completed`, `chain_pr_opened`, `chain_review_completed`, `chain_completed`, `chain_run_completed`.
- Join keys are `run_id`, `chain_run_id`, and `issue_run_id`; the same keys appear in events, prompts, PR comments, issue comments, worker summaries, and private reports.
- Worker summaries capture model/token/test data when available and list missing fields in `telemetry_gaps`.

Use the default plan before a new manifest shape or a risky chain. Dry-run prints branch, worktree, spawn, PR, review, and cleanup commands without mutating git or GitHub. Use `--yes` only after the plan is acceptable.

Chain mode is for studio-repo issue chains. It does not run user-project task work; that remains `/chanakya` / `/achilles`.

Chain branch names are safety-checked before any fetch/push. The runner refuses invalid Git branch names, a branch equal to the base, and protected direct-integration names such as `main`, `master`, `trunk`, `develop`, or `production`.

## Step 1 — Identify track

From the arg or `STUDIO_TRACK` env var. Validate against `TRACKS.md` (branch must exist, label must exist).

Use a dedicated worktree for the track branch. The track branch starts from `main` and accumulates the per-issue commits. Individual issues do not get their own PRs.

## Step 2 — Claim next issue

Run `scripts/track-next.sh <track>`.

- Exit 0: directive printed — read it, proceed to Step 3.
- Exit 1: either `TRACK_COMPLETE` (all issues done — stop) or `TRACK_BLOCKED` (every open issue has an open `Blocked by:` dependency — stop and report).

The script handles branch checkout, `git pull`, GH assignment, and `Blocked by: #N` filtering atomically. Do not repeat those steps manually.

## Step 3 — Implement

Read the issue body. It is the full spec only if it has already been shaped well enough to execute.

Before implementing, run a scope-shaping checkpoint:

- If the issue has goal, impact, acceptance criteria, clear before/after behavior, non-goals or equivalent scope boundaries, and no obvious missed edge case, proceed.
- If the issue appears to be a raw idea that was not shaped through `/studio ingest`, or if the implementation would benefit from a materially better scope, stop before editing and offer a short refined plan for user review.
- If the refinement changes behavior, cost, priority, runtime risk, ownership, or file ownership, do not proceed until the user approves or redirects.
- If the issue is small, mechanical, and already clear, do not add ceremony; proceed.

When stopping for shaping, include the command the user can use to capture the refined idea:

```
/studio ingest "<refined studio-work proposal>"
```

After the checkpoint passes, implement exactly the approved scope. No more.

**Studio repo work (not iOS):** implement directly — write scripts, edit mode packs, update SKILL.md, add fixtures. Do not spawn Achilles.

**File ownership rule:** only touch files in this track's ownership column in `TRACKS.md`. If an implementation requires a file owned by another track, stop and surface to the user instead of editing it.

## Step 4 — Per-issue gate

Individual issues on a track do not open PRs and do not run the headless PR reviewer.

Before committing, still honor local safety gates:

- pre-commit hooks run normally
- if the diff touches any `scripts/*.sh`, `SKILL.md`, or `_shared/*` file, or is >100 lines, walk `REVIEW.md` rules locally
- auto-fix `block+auto-fix` tier silently
- surface `ask` tier before changing
- note `warn` tier in the commit message

## Step 5 — Commit

Commit to the track branch (`track/<name>`), not `main`. Commit message: one-line summary + `Closes #N` trailer. Co-author line.

```
git commit -m "$(cat <<'EOF'
<summary>

Closes #N
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

## Step 6 — Close issue

```
gh issue close <N> --comment "Implemented in $(git rev-parse --short HEAD) on track/<name>."
```

## Step 7 — Loop

Run `scripts/track-next.sh <track>` again. If exit 0, go to Step 3. If exit 1 with `TRACK_COMPLETE`, proceed to Step 8. If exit 1 with `TRACK_BLOCKED`, stop and apply `modes/summary.md`.

Print a one-line checkpoint after each closed issue so the user can interrupt:
```
✓ #N closed. Picking next issue...
```

## Step 8 — Final track PR

When the track is complete:

1. Rebase the track branch on current `main`.
2. Open one PR from `track/<name>` to `main`.
3. Run the normal final review path:
   - local `REVIEW.md` pass for the final PR diff
   - `scripts/pr-headless-review.sh <pr> --method auto`
4. If the review is non-blocked, let the autopilot merge path complete.
5. Delete the remote track branch, prune refs, and remove the track worktree when the merge is confirmed.
6. Apply `modes/summary.md`.

Do not merge unreviewed final track work. Do not push directly to `main`.

## Step 9 — Completion report

When the work loop stops for any reason, apply `modes/summary.md` before the final response.

The report must cover:

- issues claimed, closed, skipped, or blocked
- PR URL, review verdict, merge commit, and cleanup status when a final PR ran
- branch name and latest commit(s)
- files or workflow surfaces changed
- verification commands run, or explicitly not run
- user-pending decisions separated from automated work
- the next command to resume the track when applicable
- whether it is safe to end the session

## When to stop without completing

- File ownership conflict (Step 3)
- Per-issue gate surfaces an `ask`-tier finding (Step 4)
- Build/test failure that needs user judgment
- Scope-shaping checkpoint needs user approval (Step 3)
- Final PR review blocks the merge (Step 8)

In all cases: report clearly what was done, what was left, and what the user needs to decide.

## Cross-track dependency

`scripts/track-next.sh` already filters out issues whose `Blocked by: #N` references are still open — the loop never claims a blocked issue. If every open issue on the track is blocked, the script exits with `TRACK_BLOCKED`; report the state to the user (usually means work on a prerequisite track stalled).
