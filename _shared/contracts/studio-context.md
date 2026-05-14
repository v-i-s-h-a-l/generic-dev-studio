---
name: Studio Context Contract
description: Canonical context envelope for Studio path, auth, and visibility resolution.
type: contract
schema_version: 1
---

# Studio Context Contract

Studio runtime state must be resolved from an explicit context envelope, not
from raw ambient `HOME`. Host launchers may set synthetic homes, temporary
homes, or reviewer-specific homes; those values are process facts, not durable
Studio truth.

This contract defines the fields every resolver layer must understand before
the control-plane context migration begins. It does not migrate callers by
itself.

## Context Envelope

| Field | Required | Meaning | Source |
|---|---:|---|---|
| `studio_home` | yes | Durable Studio state root. Usually `<login_home>/.dev-studio`; never inferred from synthetic host homes. | Context resolver |
| `project_slug` | yes for project work | Stable project key, normally the repo toplevel basename unless an explicit project override is supplied. | Resolver or caller |
| `repo_root` | yes for repo work | Git worktree root for the current checkout. Temporary worktrees are valid repo roots, but not durable state roots. | Caller or `git rev-parse` |
| `host_profile` | yes | Logical host identity, such as `claude-code`, `codex`, `codex-reviewer`, `claude-reviewer`, or future `gemini` profiles. | Launcher or resolver |
| `auth_home` | yes for auth operations | Home/config root whose credentials the selected host may use. | Host profile |
| `github_home` | yes for GitHub operations | Home/config root used for `gh` and Git credential lookups. May equal `auth_home`, but is modeled separately. | Host profile |
| `runtime_owner` | yes | Owner of writes: `project`, `machine`, `host`, `reviewer`, or `temporary`. | Resolver |
| `data_visibility` | yes | Visibility class: `public-repo`, `private-runtime`, `host-auth`, `secret`, or `temporary`. | Resolver or caller |
| `project_board` | yes for PM-surface operations | Per-project Projects v2 board identity (`owner_kind`, `owner_login`, `project_number`, `linked_repo`, allowed `tracks`, allowed `phases`). | Per-project board config under the [PM Surface portability contract](../../PM-SURFACE.md#per-project-project-board-portability-contract) |

Scripts may infer `project_slug` from `repo_root` when the operation is scoped
to the current repository. Scripts must not infer `studio_home`, `auth_home`, or
`github_home` from raw ambient `HOME` unless the context resolver has already
classified that home as safe for the requested ownership and visibility class.
Scripts must not infer `project_board` from ambient state — see the
[Project Board Resolution](#project-board-resolution) rules below.

## Root Types

| Root type | Owner | Visibility | Examples | Rules |
|---|---|---|---|---|
| Durable shared Studio state | Project or machine | Private runtime | `~/.dev-studio/<project>/plans`, `~/.dev-studio/<project>/events` | Resolve from `studio_home`; do not use synthetic host homes. |
| Per-project runtime state | Project | Private runtime | `~/.dev-studio/<project>/.runtime/state`, chain runs, checkpoints | Resolve from `studio_home` plus `project_slug`. |
| Machine-global runtime | Machine | Private runtime | `~/.dev-studio/.runtime/nodes.json`, machine locks | Resolve from `studio_home`; only machine-shared resources belong here. |
| Host auth | Host or reviewer | Host auth / secret | Claude, Codex, Gemini, reviewer configs | Resolve from `host_profile`; never copy into Studio state. |
| GitHub auth | Host or reviewer | Host auth / secret | `gh` config, Git credentials | Use `github_home`; assistant-initiated GitHub calls still go through `scripts/studio-gh.sh`. |
| Project board config (durable) | Project | Public repo | `profiles/<slug>/project-board.yaml` | Repo-checked board identity and project-defined `Track`/`Phase` value sets. |
| Project board config (runtime override) | Project | Private runtime | `<studio_home>/<project_slug>/config/project-board.yaml` | Per-machine override of durable board config; overrides MUST be surfaced to the user. |
| Project checkout | Temporary or project | Public repo plus local diff | Main checkout, issue worktree, chain worktree | Resolve as `repo_root`; never treat it as durable runtime state. |
| Temporary artifacts | Temporary | Temporary | `$TMPDIR/studio-chain-runner/**`, scratch scans | May be regenerated; any resume-critical reference must also be recorded under durable Studio state. |

Data ownership and auth ownership are independent. A chain report belongs to
the project even when Codex writes it. A GitHub token belongs to the host auth
profile even when a project-scoped command needs it.

## Resolver Layer

The approved resolver layer is a single Studio context resolver, exposed to
shell callers before migration as `scripts/lib-studio-context.sh`. Until that
helper exists, `scripts/lib-paths.sh` remains the compatibility layer and must
not grow new broad HOME inference rules except as a bridge to this contract.

The resolver is responsible for:

- Normalizing login-home, synthetic-home, reviewer-home, and temporary-home
  cases into the envelope fields above.
- Returning loud errors for missing, contradictory, or unsafe context.
- Providing shell-safe accessors for `studio_home`, project runtime roots, auth
  homes, GitHub homes, and temporary roots.
- Emitting enough diagnostic detail for the caller to fix setup without
  printing secrets.
- Preserving current user-controlled bypasses while making bypass use explicit
  in events, reports, or stderr.

Callers are responsible for passing their intended operation class:
read-only, runtime mutation, repo mutation, GitHub operation, delegated host
spawn, release action, or test/debug fixture. The resolver may only infer paths
that are safe for that operation class.

## Project Board Resolution

PM-surface operations require a `project_board` envelope field. The resolver
populates it by walking, in order:

1. Explicit CLI flag, e.g. `--project-board <owner_kind>:<owner_login>:<n>`.
2. Environment override `STUDIO_PROJECT_BOARD_OVERRIDE=<owner_kind>:<owner_login>:<n>`.
3. Runtime override file at `<studio_home>/<project_slug>/config/project-board.yaml`.
4. Durable repo file at `profiles/<slug>/project-board.yaml` inside `repo_root`.
5. Loud failure naming the missing config and `project_slug`.

The resolver MUST NOT silently fall back to another project's board when the
current project lacks board config. The field contract — which fields are
fixed cross-project and which are project-defined — is owned by
[PM-SURFACE.md §Per-Project Project Board Portability Contract](../../PM-SURFACE.md#per-project-project-board-portability-contract).
Steps 1 and 2 are user-controlled bypass surfaces and MUST follow the bypass
policy below.

## Loud-Failure Rules

The resolver must fail before mutation when:

- `studio_home` points inside a synthetic host home such as `.codex-homes`.
- A durable write would land in a temporary worktree or `$TMPDIR` path.
- `repo_root` is missing for a repo mutation.
- `project_slug` conflicts with an explicit project override.
- `auth_home` or `github_home` is missing for an operation that needs host or
  GitHub credentials.
- A reviewer profile would inherit the parent host's general auth home.
- A secret-class path would be written under public repo content.
- A temporary artifact is recorded as the only resume-critical location.
- `project_board` is required for the operation but no durable, runtime, or
  override source supplies it for the current `project_slug`.

Errors should name the missing or unsafe field, the attempted operation class,
and the user-controlled override if one exists. Errors must not print tokens,
credential file contents, or private project details outside private runtime
artifacts.

## Bypass Policy

Bypasses are for user-directed emergency, migration, and test/debug workflows.
Assistants must not set bypass variables silently to make a failing operation
pass.

Allowed bypass shape:

- Environment variable or flag with a narrowly named purpose, such as
  `STUDIO_BYPASS_PARENT_HOME_FLIP=1`.
- Documented scope, risk, and expected use.
- Event/report/stderr evidence that the bypass was active.
- No widening of credential access beyond the selected host profile.

Tests may construct synthetic homes and bypasses, but production scripts must
default to fail-loud behavior.

## Multi-Account Host Profiles

Host profiles are explicit records, not guessed usernames. A profile should be
able to describe:

- Host kind: Claude Code, Codex, Gemini, reviewer, or future adapter.
- Auth home: host-specific configuration root.
- GitHub home: credential root for `gh` and Git.
- Secret floor: whether delegated processes receive no secrets, host auth,
  GitHub auth, release auth, or a narrower reviewer scope.
- Data visibility allowed for reads and writes.
- Account label, when useful for diagnostics, without exposing credentials.

The same machine may have multiple Claude, Codex, Gemini, and GitHub accounts.
Selection must come from the context envelope, project profile, command flag, or
user-approved setup, not from whichever account ambient `HOME` happens to show.

## Migration Implications

Later implementation issues should migrate callers in this order:

1. GitHub wrappers and review wrappers, because auth-home mistakes can leak or
   fail noisily.
2. Chain-runner, monitor, checkpoint, and resume paths, because temporary paths
   must not be the only durable references.
3. Feedback ingest/analyze/reconcile and project-profile lookup, because these
   cross project and Studio context boundaries.
4. Remaining docs, tests, and fixtures, preserving intentional synthetic-home
   coverage.

This contract is satisfied when every durable Studio write is rooted in
`studio_home`, every credential read is rooted in the selected host profile, and
raw ambient `HOME` is treated only as an input to the resolver, never as the
source of durable truth.
