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
   - A role token with no remaining request starts that role's lightweight
     landing. Load the role contract, inspect only cheap cwd/profile context,
     and offer next moves instead of running a heavy default action.
   - Unknown role tokens fail before side effects.

5. Execute the matched role workflow by following the router and role contract:
   - `manager` -> shaping, status, resume, ingest, guard, audit, or a
     cwd-aware landing when no subcommand/request is present.
   - `worker` -> bounded task contract in an isolated worktree.
   - `reviewer` -> plan, outcome, diff, PR, or release-packet review.
   - `perf` -> performance, battery, memory, thermal, network, or instrumentation evidence.
   - `planner`, `qa-engineer`, `flow-tester`, `release-manager` -> active role contracts, usually manager-mediated or approval-gated.

6. Keep project state under `~/.dev-studio/$PROJECT_SLUG/` unless the user
   explicitly names another project slug. For `manager ingest`, call
   `$STUDIO_REPO/scripts/dev-studio-ingest-resolve.sh --cwd "$PROJECT_ROOT"`
   with any explicit `--scope` or `--to` arguments and follow its JSON route.
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

## Notes

Former top-level v1 names are aliases under this command, not restored v1
surfaces. For example, `/dev-studio apollo profile` resolves to
`/dev-studio perf profile`.

`scripts/dev-studio-ingest-resolve.sh` owns ingest destination semantics. Its
JSON includes `destination_project`, `scope`, `artifact_kind`, `artifact_root`,
`public_issue_repo`, `requires_privacy_scrub`, and `local_ingest_policy`.
Project profiles decide what a project-local ingest becomes after routing:
private artifact, GitHub issue, task, or backlog entry.
