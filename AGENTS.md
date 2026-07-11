# Client Project — SDL Governance

This repository is governed through SDL (stibdedlom). The contract is
agent-neutral: it works with Kimi, Claude, Cursor, headless scripts, and any
future agent that can shell out to `sdl-orchestrator check`.

## Default SDL routing

SDL is active by default. The user does not need to invoke a magic phrase.
Treat every user prompt as an invocation-policy `user_prompt`: inquiry may
answer after routing, planning routes through governance, and execution routes
to the selected capability or role with a lifecycle record plus isolated
branch/worktree before mutation.

To opt out for a bounded session or task, say `SDL off for this task`.

## Project reference

```text
project://v-i-s-h-a-l/generic-dev-studio
```

## Memory boundary

Project memory is stored out-of-band at:

```text
/Users/vishalsingh/.stibdedlom/project-memory/v-i-s-h-a-l/generic-dev-studio
```

No client data, secrets, or project memory may be committed to this repository.

## Agent integration contract

The repository declares its SDL contract in `.stibdedlom/manifest.yaml` under
the `agent_integration` section. Any agent can discover:

- `memory_root` — where project memory and trust material live.
- `check_command` — how to invoke `sdl-orchestrator check`.
- `attested` — whether mutations require a valid routing attestation.

Example `sdl-orchestrator check` invocation:

```text
sdl-orchestrator check \
  --tool file_write \
  --tool-args '{"path": "docs/example.md", "content": "hello"}' \
  --target-paths docs/example.md \
  --task-ref issues/123 \
  --intent-class execution
```

## Modes

- **Attested mode** (`agent_integration.attested: true`): the agent has a valid
  routing attestation for the current branch/task. Call `sdl-orchestrator check`
  before every mutation. The kernel returns `allow`, `block`, or `escalate`.
- **Unattested mode** (`agent_integration.attested: false`): only read-only and
  diagnostic operations are permitted until an attestation is created.

## Picking up a classified issue

When an issue carries an SDL classification block, route it through SDL:

```text
/sdl-pickup <issue-url>
```

This extracts the classification block, routes the goal, and initializes a
lifecycle record. Agents without `/sdl-pickup` support can create the lifecycle
record manually via `scripts/lifecycle/new-record.sh` in the infra repo.

## Authority

- Live mutations require explicit bounded authorization.
- Commits that change governed files must carry `SDL-Commit-Author` and
  `SDL-Routing-Attestation` trailers.
- Merges require independent review and merge-queue submission.
- Promotion and provider dispatch follow the SDL lifecycle gates.
