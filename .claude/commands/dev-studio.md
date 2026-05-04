---
description: Studio v2 umbrella router. Dispatches by canonical role: manager, worker, reviewer, perf, planner, qa-engineer, flow-tester, release-manager.
allowed-tools: [Bash, Read]
argument-hint: "[role] [request]"
---

# dev-studio

Thin Claude Code slash-command wrapper for the repo-local Studio v2 router.

## Steps

1. Resolve the repo root:

   ```bash
   REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
   ```

2. Read `$REPO_ROOT/core/v2/skills/dev-studio/SKILL.md`.

3. Parse `$ARGUMENTS`:
   - Empty arguments route to `manager`.
   - A canonical role or compatibility alias in the first token routes through
     `scripts/v2-role-resolve.sh`.
   - Unknown role tokens fail before side effects.

4. Execute the matched role workflow by following the router and role contract:
   - `manager` -> shaping, status, resume, ingest, guard, audit.
   - `worker` -> bounded task contract in an isolated worktree.
   - `reviewer` -> plan, outcome, diff, or PR review.
   - `perf` -> performance, battery, memory, thermal, network, or instrumentation evidence.
   - `planner`, `qa-engineer`, `flow-tester`, `release-manager` -> active role contracts, usually manager-mediated or approval-gated.

5. If the user asks for help, open:

   ```bash
   open "$REPO_ROOT/core/v2/skills/dev-studio/docs.html"
   ```

   Then say: "Studio v2 router docs opened. Path in the repo:
   `core/v2/skills/dev-studio/docs.html`."

## Notes

Former top-level v1 names are aliases under this command, not restored v1
surfaces. For example, `/dev-studio achilles T123` resolves to
`/dev-studio worker T123`.
