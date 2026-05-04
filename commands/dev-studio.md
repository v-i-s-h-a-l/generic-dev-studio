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
   - Empty arguments route to `manager`.
   - A canonical role or compatibility alias in the first token routes through
     `$STUDIO_REPO/scripts/v2-role-resolve.sh`.
   - Unknown role tokens fail before side effects.

5. Execute the matched role workflow by following the router and role contract:
   - `manager` -> shaping, status, resume, ingest, guard, audit.
   - `worker` -> bounded task contract in an isolated worktree.
   - `reviewer` -> plan, outcome, diff, or PR review.
   - `perf` -> performance, battery, memory, thermal, network, or instrumentation evidence.
   - `planner`, `qa-engineer`, `flow-tester`, `release-manager` -> active role contracts, usually manager-mediated or approval-gated.

6. Keep project state under `~/.dev-studio/$PROJECT_SLUG/` unless the user
   explicitly names another project slug. Use studio scripts from
   `$STUDIO_REPO/scripts/`.

7. If the user asks for help, open:

   ```bash
   open "$STUDIO_REPO/core/v2/skills/dev-studio/docs.html"
   ```

   Then say: "Studio v2 router docs opened. Path in the repo:
   `core/v2/skills/dev-studio/docs.html`."

## Notes

Former top-level v1 names are aliases under this command, not restored v1
surfaces. For example, `/dev-studio apollo profile` resolves to
`/dev-studio perf profile`.
