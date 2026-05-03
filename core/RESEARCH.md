# Studio v2 OSS Research Map

Research date: 2026-05-03

Issue anchor: #444 A0 / #507. This document is the A0 research pass for the
Studio v2 substrate. It maps the 12 canonical v2 principles to observed OSS
agent patterns and records the delta Studio v2 introduces before A0.5
`SPEC.md` locks the substrate.

## Sources Reviewed

Primary sources used for this pass:

- [Superpowers (`obra/superpowers`)](https://github.com/obra/superpowers) for
  skill-pack workflow discipline, composable skills, task worktrees, and staged
  review.
- [CrewAI agents docs](https://docs.crewai.com/core-concepts/Agents/) and
  [CrewAI Flows](https://www.crewai.com/crewai-flows) for role/task/crew
  separation, flow orchestration, and Pydantic-style structured outputs.
- [Microsoft AutoGen AgentChat docs](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/messages.html)
  and the [AutoGen paper](https://arxiv.org/abs/2308.08155) for multi-agent
  conversation patterns, message types, and declarative Agent Studio
  experiments.
- [Aider repo-map docs](https://aider.chat/docs/repomap.html) and
  [coding conventions docs](https://aider.chat/docs/usage/conventions.html) for
  context compression and conventions-as-context.
- [OpenHands](https://github.com/OpenHands/OpenHands) and the
  [OpenHands paper](https://arxiv.org/abs/2407.16741) for software-agent
  runtime shape, CLI/browser/file interaction, sandboxing, and agent SDK
  direction.
- [Block goose extensions docs](https://block.github.io/goose/docs/getting-started/using-extensions)
  for extension-based tool surfaces and MCP-based integration.
- [Cline interactive-mode docs](https://docs.cline.bot/cline-cli/interactive-mode)
  and [Cline SDK docs](https://docs.cline.bot/cline-sdk/overview) for Plan/Act
  separation and explicit permission handling.
- [Claude Agent SDK subagents](https://code.claude.com/docs/en/agent-sdk/subagents),
  [hooks](https://platform.claude.com/docs/en/agent-sdk/hooks), and
  [plugins](https://docs.claude.com/en/docs/agent-sdk/plugins) docs for
  subagents, hooks, plugins, and permission-scoped specialized agents.

## Principle Map

| # | Studio v2 principle | OSS pattern observed | Studio v2 delta |
|---|---|---|---|
| 1 | Reduce human involvement | Superpowers and Cline both separate plan/review from execution; CrewAI and AutoGen model repeatable multi-step work as orchestrated flows rather than one long prompt. | Make automation the default path while preserving the user as an explicit override. Human checkpoints move to phase gates, irreducible conflicts, and release sign-off, not routine worker/reviewer handoffs. |
| 2 | Research before locking | Superpowers, CrewAI, AutoGen, Aider, OpenHands, goose, Cline, and Claude Agent SDK each solve different parts of the substrate: skills, typed outputs, conversation routing, context compression, sandboxed software work, extensions, plan/act boundaries, and subagents. | A0 records the prior art before A0.5. Studio adopts patterns, not frameworks: no wholesale dependency on an agent framework and no runtime dependency introduced by this research pass. |
| 3 | Host-agnostic core | Superpowers uses portable skills; goose uses extensions; Claude Agent SDK exposes host-native subagents/hooks; OpenHands provides an agent runtime; Aider keeps core behavior CLI/file oriented. | The core contract is file I/O, POSIX shell, structured artifacts, and one model session. Host adapters expose richer host-native features only as optional capabilities. A0a owns the detailed capability matrix. |
| 4 | Sibling-host plan/task review | Superpowers emphasizes staged task review; AutoGen demonstrates multi-agent critique loops; Claude Agent SDK supports specialized subagents, including read-only reviewers. | Major Studio plans and phase outcomes require sibling-host review through the existing smoke-gated wrapper, not raw host spawns. The review primitive remains centralized so auth-home selection, no-secret env scrubbing, and failure detail stay consistent. |
| 5 | Task size discipline (S/M only) | CrewAI tasks and flows encourage bounded units; Superpowers batches work into reviewed tasks; Cline Plan mode makes scope explicit before Act mode. | Studio makes sizing a gate, not advice. Planners decompose L/XL work, combine related XS into M when it reduces overhead, and later gates block oversized leaves before they reach workers. |
| 6 | Feature branch flow | Superpowers uses isolated worktrees; common coding-agent tools expect git-native diffs; OpenHands and Aider operate against normal repositories. | Studio keeps the chain branch as the integration lane. Leaf workers branch/worktree from the feature branch, commit scoped work, and return through reviewed PR/chain integration. Direct main pushes remain forbidden. |
| 7 | Unit tests after acceptance for feature-integration logic; during development for primitives only | CrewAI/AutoGen structured outputs make pure helpers easy to test early; coding agents commonly overfit tests when integration behavior is still in flux. | Studio distinguishes primitives from feature-integration logic. Pure protocols, parsers, validators, and schemas get tests while built; end-to-end feature tests harden after acceptance criteria settle. |
| 8 | UI tests during feature development | Cline and Claude Code can drive UI-adjacent tasks with tools; OpenHands models browser/CLI interaction as first-class agent actions. | For user-facing features, UI tests are not deferred to release polish. They are part of development when the user flow is known, with deterministic selectors and flow-tester ownership defined by A0d/A7+ work. |
| 9 | Manual test workflow updated per TF build | No surveyed OSS project fully covers app-store/TestFlight human test workflows. Release/checklist responsibility is usually left outside the agent substrate. | Studio introduces a flow-tester/release-manager contract: every TF build gets an updated user-flow checklist tied to what changed. This is a Studio-specific product-delivery obligation, not borrowed OSS behavior. |
| 10 | Each TF build tagged; each App Store release has GH release notes | OSS tools commonly use git tags and release notes, but agent frameworks rarely make mobile build lineage a substrate rule. | Studio treats build lineage as a release invariant. Tags and GitHub releases become required release artifacts, with A11 owning message style and duplicate detection. |
| 11 | Standard build/release messaging language | Existing tools provide status output, but not a shared product-facing message style across workers, release notes, TestFlight notes, and App Store copy. | Studio adds `MESSAGES.md` and a duplicate-detection linter in A11 so build/release language is consistent, non-duplicative, and reviewable. |
| 12 | Built-in telemetry | CrewAI Flows and AutoGen Studio emphasize observability and state; OpenHands has runtime traces; Claude hooks expose event points. | Studio keeps telemetry in append-only artifacts and raw counters first. Auto-suggestions wait until enough data exists; A4/A4a define durable event semantics and weekly metrics before higher-level inference. |

## Cross-Cutting Lessons

### Adopt patterns, not frameworks

CrewAI, AutoGen, OpenHands, goose, Cline, Aider, Superpowers, and Claude Agent
SDK each imply useful substrate ideas, but none is the Studio substrate. Studio
v2 should preserve a zero-third-party-runtime core and express reusable behavior
as schemas, shell-reachable validators, and markdown/YAML contracts.

### Treat host features as capability-gated accelerators

Subagents, hooks, plugins, MCP servers, and browser/UI automation are useful, but
they are unevenly available across hosts. A host adapter can expose them; the
core must not require them. The fallback shape is always explicit artifacts plus
shell execution, with loud unsupported states instead of silent no-ops.

### Keep context loading explicit

Aider's repo-map pattern, Superpowers' skill packs, and Claude/Cline planning
surfaces all point at the same pressure: agents need focused context. Studio v2
should make context loading role-aware and budget-aware, then validate it with
observable behavior instead of relying on long always-loaded instructions.

### Encode review and handoff as contracts

OSS multi-agent frameworks converge on typed messages or structured outputs.
Studio v2 should carry that further: every role boundary needs a schema,
authority rules, idempotency behavior, and failure semantics. This feeds A0d and
A0.5 directly.

### Preserve mobile-release obligations as Studio-specific doctrine

The OSS prior art is strongest for coding loops and weakest for TestFlight,
manual test checklists, App Store release notes, and product-facing build
messaging. Studio v2 must keep those as first-class substrate requirements
rather than hoping generic agent frameworks cover them later.

## Implications for A0.5 SPEC

A0.5 `SPEC.md` should incorporate these research conclusions:

- Core primitives are schemas, file artifacts, shell commands, and host adapters.
- Host-native features are capability-gated, never load-bearing without a
  portable fallback or a loud unsupported state.
- Roles communicate through typed handoff artifacts, not implicit conversation
  state.
- Context budget enforcement belongs in the substrate, not inside individual
  agent prose.
- Review gates and phase gates are substrate contracts, not optional process.
- Release/test messaging is a first-class product workflow, not a side note.

## Carryover to Later A0 Leaves

- A0a: Turn the host-agnostic observations into a claude/codex/gemini/ollama
  capability matrix.
- A0b: Specify durable event semantics for ordering, dedupe, replay, locks, and
  backpressure.
- A0c: Specify auth, permissions, token boundaries, and failure behavior.
- A0d: Define role topology, authority, handoff schemas, and contract failures.
- A0.5: Convert A0 through A0d into the normative substrate `SPEC.md`.
