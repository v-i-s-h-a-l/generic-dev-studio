---
description: Studio v2 umbrella router. Dispatches by canonical role from any project: manager, worker, reviewer, perf, planner, qa-engineer, flow-tester, release-manager.
allowed-tools: [Bash, Read]
argument-hint: "[role] [request]"
---

# dev-studio

Global Claude Code wrapper for the Studio v2 router.

This command is intentionally global: invoke it from the project you are
working on. The studio repo supplies the router and scripts; the current project
supplies the task context and runtime slug.

## Steps

1. Resolve the current project:

   ```bash
   PROJECT_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
   PROJECT_SLUG="$(basename "$PROJECT_ROOT")"
   ```

2. Resolve the studio repo:

   ```bash
   STUDIO_REPO="${STUDIO_REPO_DIR:-$HOME/Documents/v-i-s-h-a-l/github/generic-dev-studio}"
   [ -f "$STUDIO_REPO/core/v2/skills/dev-studio/SKILL.md" ] || {
     echo "error: set STUDIO_REPO_DIR to your generic-dev-studio checkout" >&2
     exit 1
   }
   ```

3. Read `$STUDIO_REPO/core/v2/skills/dev-studio/SKILL.md`.

4. Parse `$ARGUMENTS`:
   - Empty arguments route to the lightweight `manager` landing.
   - A canonical role or compatibility alias in the first token routes through
     `$STUDIO_REPO/scripts/v2-role-resolve.sh`.
   - Store any session-local active role only in the host conversation context,
     using the resolved canonical role after alias resolution. Do not write
     active-role state to disk or env vars.
   - If no role token is present and the current session has a clear active
     role, resolve unambiguous bare subcommands through that active role.
     Explicit `/dev-studio <role> ...` always wins and replaces the active role
     for that invocation. Bare `/dev-studio` re-lands in `manager` and clears
     any assumed active-role shortcut.
   - Bare `help` with no active role shows the router-level role index. Bare
     `help` with an active role shows that role's help. `<role> help` always
     shows that role's available commands, examples, aliases, and shared
     lifecycle actions.
   - A role token with no remaining request starts that role's lightweight
     landing. Load the role contract, inspect only cheap cwd/profile context,
     and offer next moves instead of running a heavy default action.
   - Bare `/dev-studio checkpoint` and `/dev-studio resume-checkpoint` always
     land in `manager`; role-qualified lifecycle commands are owned by the
     named role. Do not let active-role shortcuts swallow those bare slash
     invocations.
   - Unknown role tokens fail before side effects.

5. Execute the matched role workflow by following the router and role contract:
   - `manager` -> shaping, status, resume, ingest, guard, audit, or a
     cwd-aware landing when no subcommand/request is present.
     Manager asks depth-first clarification before lock-in when material
     assumptions affect scope, cost, user-visible behavior, verification, or
     role routing. Manager ingest may suggest missing/refined inputs from
     PRD, Figma, issue, plan, or repo context already provided in the
     session/repo; it does not auto-fetch unavailable sources or decompose
     planner-owned work.
   - `worker` -> bounded task contract in an isolated worktree.
   - `reviewer` -> plan, outcome, diff, PR, or release-packet review.
   - `perf` -> performance, battery, memory, thermal, network, or instrumentation evidence.
   - `planner`, `qa-engineer`, `flow-tester`, `release-manager` -> active role contracts, usually manager-mediated or approval-gated.
   - `release-manager configure` -> project-scoped release notification setup;
     call `$STUDIO_REPO/scripts/release-manager-configure.sh` after shaping
     quick/custom/descriptive Slack options with the user.
   - `host-adapter` -> nodes, sync, host capability, and host skill refresh.
   - `operator` -> human authority marker only; surface an explicit decision
     instead of pretending to execute a runnable role.

   Bare subcommand ownership:

   | Command | Owner | Example |
   |---|---|---|
   | `help` | router or active role | `/dev-studio help`, `/dev-studio manager help` |
   | `status` | manager | `status` after `/dev-studio manager` |
   | `resume-plan` | manager | `/dev-studio manager resume-plan` |
   | `ingest` | manager | `ingest "capture this"` |
   | `guard` | manager | `guard "has this shipped?"` |
   | `audit` | manager | `audit` |
   | `analyze` | manager | `/dev-studio manager analyze` |
   | `reconcile` | manager | `reconcile` in a project repo |
   | `add` | manager | `/dev-studio manager add <url>` |
   | `sync` | host-adapter | `/dev-studio host-adapter sync` |
   | `nodes` | host-adapter | `/dev-studio host-adapter nodes` |
   | `review` | reviewer | `/dev-studio reviewer review` |
   | `plan` | planner | `/dev-studio planner plan issue 123` |
   | `profile` | perf | `/dev-studio perf profile editor startup` |
   | `qa` | qa-engineer | `/dev-studio qa-engineer help` |
   | `flow`, `flow-test` | flow-tester | `/dev-studio flow-tester help` |
   | `release`, `tf-push` | release-manager | `/dev-studio release-manager tf-push --background` |
   | `configure` | release-manager only when active or prefixed | `/dev-studio release-manager configure` |
   | `checkpoint`, `resume-checkpoint` | lifecycle special | `/dev-studio worker checkpoint` |

6. Keep project state under `~/.dev-studio/$PROJECT_SLUG/` unless the user
   explicitly names another project slug. For `manager ingest`, call
   `$STUDIO_REPO/scripts/dev-studio-ingest-resolve.sh --cwd "$PROJECT_ROOT"`
   with any explicit `--scope` or `--to` arguments and follow its JSON route.
   For `manager analyze`, call
   `$STUDIO_REPO/scripts/manager-analyze.sh --cwd "$PROJECT_ROOT"`. It is
   studio-checkout only; if invoked from a project checkout, surface the
   script's refusal and point to `manager reconcile`. For `manager reconcile`,
   call `$STUDIO_REPO/scripts/manager-reconcile.sh --cwd "$PROJECT_ROOT"`.
   Use studio scripts from `$STUDIO_REPO/scripts/`.

7. For a bare-role landing:
   - In `generic-dev-studio`, include studio-internal options such as
     `resume-plan`, `ingest`, `guard`, `audit`, `sync`, and `nodes` when they
     match the selected role.
   - In project repos, bias suggestions toward project task shaping,
     implementation, review, QA, flow testing, performance, and release
     readiness.
   - After the user locks in a workflow, continue without requiring them to
     retype the command and report the reusable direct invocation for next
     time.

8. If the user asks for help, open:

   ```bash
   open "$STUDIO_REPO/core/v2/skills/dev-studio/docs.html"
   ```

   Then say: "Studio v2 router docs opened. Path in the repo:
   `core/v2/skills/dev-studio/docs.html`."

   If the user asks for role help in chat instead of opening docs, summarize
   from this index:

   - `manager`: `status`, `resume-plan`, `ingest`, `guard`, `audit`,
     `analyze`, `reconcile`, `add`; examples: `/dev-studio manager ingest
     "capture this"`, `/dev-studio manager reconcile`.
   - `worker`: bounded contract execution plus `checkpoint` and
     `resume-checkpoint`; example: `/dev-studio worker T123`.
   - `reviewer`: `review`, plan/outcome/diff/PR/release-packet review plus
     lifecycle actions; example: `/dev-studio reviewer review`.
   - `perf`: `profile` and metric investigation requests plus lifecycle
     actions; example: `/dev-studio perf profile editor startup`.
   - `planner`: `plan` and decomposition requests plus lifecycle actions;
     example: `/dev-studio planner plan issue 123`.
   - `qa-engineer`: QA target and test-contract requests plus lifecycle
     actions; example: `/dev-studio qa-engineer write QA targets for T123`.
   - `flow-tester`: exploratory flow scenarios and checklists plus lifecycle
     actions; example: `/dev-studio flow-tester check onboarding on build 456`.
   - `release-manager`: `release`, `configure`, `tf-push`, release packets,
     and lifecycle actions; examples: `/dev-studio release-manager configure`,
     `/dev-studio release-manager tf-push --background`.
   - `host-adapter`: `nodes`, `sync`, host capability checks; example:
     `/dev-studio host-adapter nodes`.
   - `operator`: decision authority only; surface an approval request rather
     than running a role.

## Notes

Former top-level v1 names are aliases under this command, not restored v1
surfaces. For example, `/dev-studio apollo profile` resolves to
`/dev-studio perf profile`.

`scripts/dev-studio-ingest-resolve.sh` owns ingest destination semantics. Its
JSON includes `destination_project`, `scope`, `artifact_kind`, `artifact_root`,
`public_issue_repo`, `requires_privacy_scrub`, and `local_ingest_policy`.
Project profiles decide what a project-local ingest becomes after routing:
private artifact, GitHub issue, task, or backlog entry.
