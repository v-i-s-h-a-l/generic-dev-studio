# Studio v2 Auth and Permissions Model

Status: A0c specification for issue #444. This document is the v2 target contract for A0.5 SPEC composition and A0.6 enforcement. It does not change the v1 runtime by itself.

## Relationship to Existing Contracts

Studio v1 already has several auth and permission safety floors:

- `scripts/studio-gh.sh` normalizes GitHub CLI calls through the user's login home.
- `scripts/phase-review.sh` centralizes reviewer auth-home selection, no-secret environment scrubbing, MCP isolation, sandbox-readable payload handoff, and failure-detail surfacing.
- `hosts/ADAPTER-SPEC.md` defines host adapter security floors such as sandbox profile and secret scope.
- `_shared/contracts/release-tf-push.md` defines release-action secret requirements for App Store Connect and Slack.
- `_shared/primitives/file-locations.md` defines the canonical repo and runtime roots.

Studio v2 inherits these safety floors unless A0.5 explicitly supersedes them. The target model is capability-based and least-privilege by default: every action declares the authority it needs, every host profile declares the authority it can provide, and mismatches fail before mutation.

## Scope

In scope:

- GitHub token and credential boundaries.
- Local filesystem, shell, and tool boundaries.
- Sub-agent and delegated-process boundaries.
- Release-action scopes for TestFlight, App Store, Slack, signing, and GitHub release mutation.
- Failure semantics for unsupported, unknown, missing, denied, or partial authority.

Out of scope:

- Final host capability matrix fields. A0a owns host capability inputs.
- Event-log durability. A0b owns event semantics.
- Role topology and handoff schemas. A0d owns role contracts.
- Runtime implementation of permission checks. A0.6 and later leaves own enforcement.
- Secrets storage migration. A6 owns project-profile migration details.

## Vocabulary

| Term | Meaning |
|---|---|
| Authority | A concrete permission to read, write, mutate, spawn, or publish. |
| Capability | A host-adapter-declared feature that can satisfy an authority request. |
| Secret scope | A named secret class available to a process, such as `github`, `asc`, `slack`, `signing`, or `none`. |
| Mutation scope | The external state an action may change, such as `git:branch`, `github:issue`, `github:pr`, `release:testflight`, or `release:appstore`. |
| Trust boundary | A process, host, sandbox, project, or sub-agent boundary where authority must be re-declared instead of inherited implicitly. |

## Authority Model

Every mutating v2 action must declare:

- required filesystem roots;
- required shell/tool commands;
- required secret scopes;
- required mutation scopes;
- whether the action is interactive, headless, or release-bearing;
- failure class and rollback expectations.

Declarations are matched against the selected host profile before the first irreversible side effect. A host profile may satisfy a request only when it can provide every required authority with an equal or narrower boundary.

Authority never flows by assumption. A parent session with broad permissions does not automatically authorize a child worker, reviewer, release helper, or host-specific sub-agent. Delegation creates a new trust boundary and requires a fresh authority declaration.

## GitHub Auth

GitHub operations are split by mutation scope:

| Scope | Examples | Required authority |
|---|---|---|
| `github:read` | issue lookup, PR lookup, project-state reads | authenticated read token or public unauthenticated fallback when the repo is public and the action is read-only |
| `github:issue` | create, edit, label, comment, close issues | authenticated token with issue mutation rights |
| `github:pr` | open, comment, review, merge PRs | authenticated token with PR mutation rights |
| `git:remote-read` | `git ls-remote`, fetch, dry-run credential probe | credential manager access without prompting |
| `git:remote-write` | push branch, push tags | credential manager access without prompting and explicit branch/tag target |

Assistant-initiated GitHub CLI calls route through `scripts/studio-gh.sh`. Scripts that call GitHub or credential-probing git commands source `scripts/lib-paths.sh` and wrap calls with the login-home helper. Raw `gh` is not a v2 load-bearing path.

GitHub credential failures must halt before mutation. Non-interactive tasks set no-prompt behavior for git credential probes and report `github_auth_unavailable`, `github_home_mismatch`, `github_rate_limited`, or `network_partition` instead of opening an interactive prompt.

## Local Tool Boundaries

Load-bearing v2 paths may assume only:

- repo reads and writes inside the owned worktree;
- runtime artifact reads and writes under `~/.dev-studio/**`;
- POSIX shell or host-equivalent command execution;
- declared project-profile commands;
- explicit generated artifacts written to declared paths.

New writes outside the repo or `~/.dev-studio/**` are permission-expansion requests. They require a documented user-controlled override or a setup command that the user intentionally runs. Runtime actions must not discover a missing permission and silently fall back to a broader path.

Shell commands are part of the authority request. A mode that needs `xcodebuild`, `gh`, `git push`, `open`, `osascript`, signing tools, or a package manager declares that need up front. Host adapters may deny unsupported commands; callers surface the denial as an explicit unsupported capability.

## Sub-Agent Boundaries

Sub-agent, child-process, and delegated-host work are treated as separate principals.

Delegated work receives:

- the bounded task artifact or review payload;
- the minimum repo/runtime access required for the role;
- only the secret scopes explicitly declared for that role;
- a write scope limited to the owned worktree or private runtime artifact;
- a machine-readable result artifact.

Delegated work must not receive:

- inherited full parent environment by default;
- ambient GitHub, Slack, App Store Connect, or signing secrets unless declared;
- permission to mutate the parent branch, main checkout, project board, or release state unless that is the delegated role's explicit authority;
- private analysis or chain-run artifacts beyond the bounded task envelope.

Reviewer roles default to no-secret, read-only inputs. Worker roles may receive repo write authority inside their own worktree. Release roles are the only roles allowed to receive release-action secret scopes, and only after preflight proves the selected host is authorized.

## Release-Action Scopes

Release actions are higher-risk than ordinary task work because they mutate external distribution channels.

| Scope | Allows | Must not allow |
|---|---|---|
| `release:testflight` | archive, upload, TestFlight metadata and notification flow | App Store submission |
| `release:appstore` | App Store submission and GitHub release coordination | unrelated issue/PR mutation |
| `secret:asc` | App Store Connect JWT key and issuer metadata | Slack token or signing identity by implication |
| `secret:slack` | release notification posting | GitHub or App Store mutation |
| `secret:signing` | signing assets needed by the selected profile | general keychain access |

Release drivers halt when the selected host lacks a required secret or mutation scope. Falling back from an unauthorized remote node to the local machine is diagnostic only unless the release driver explicitly re-runs preflight and records the authority change.

Release messages and GitHub release notes must not embed secret paths, token material, private key IDs beyond the minimum public identifier, or proprietary project details that the privacy rules exclude from public output.

## Failure Semantics

Auth and permission failures use explicit terminal classes:

| Class | Meaning | Required behavior |
|---|---|---|
| `unsupported` | The host or profile declares it cannot provide the capability. | Halt before mutation and report the missing capability. |
| `unknown` | The host or profile has no evidence for the capability. | Treat as denial for mutation; read-only planning may continue with an `unknown` caveat. |
| `missing` | Required credential, config, command, path, or profile field is absent. | Halt with the missing field and expected setup surface. |
| `denied` | The OS, host, API, or user denied an attempted authority. | Halt, preserve logs, and do not retry with broader authority automatically. |
| `expired` | Token/session exists but is stale or revoked. | Halt with re-auth guidance; do not prompt inside headless work. |
| `partial` | One authority succeeded and a later required authority failed. | Record what changed, stop further mutation, and emit/return a recovery artifact. |

Silent no-ops are forbidden for load-bearing behavior. If a step cannot check authority, the result is `unknown`, not success.

Best-effort telemetry may be dropped only when the caller marks it non-critical and no user-visible state depends on it. Task, review, chain, release, issue, PR, and project-board lifecycle changes are critical.

## Permission Manifest Inputs

A0.5 should define a versioned permission manifest or equivalent schema with these minimum fields:

```yaml
action: <name>
role: <manager|worker|reviewer|perf|release|helper>
filesystem:
  reads: []
  writes: []
commands: []
secret_scopes: []
mutation_scopes: []
interactive: false
headless_safe: true
failure_classes: []
override: <documented flag/env var or null>
```

A0.6 should validate that mutating modes, scripts, and chain-runner leaves either declare this model directly or consume a generated manifest that does.

## Validation Invariants for A0.6

A0.6 enforcement should validate these invariants before post-bootstrap substrate code depends on permission checks:

- Mutating actions declare secret scopes and mutation scopes.
- Reviewer profiles are no-secret unless a spec-approved exception exists.
- Worker profiles write only to their owned worktree and declared runtime artifacts.
- Release actions declare both release mutation scope and every secret scope they use.
- GitHub CLI mutations route through `scripts/studio-gh.sh` or the v2 successor wrapper.
- Raw credential prompts are disabled in headless work.
- Unsupported or unknown host capability combinations fail loud before mutation.
- Permission-expansion paths have a user-controlled override documented in the same change.
- Partial mutations return a recovery artifact instead of reporting success.

## A0.5 Composition Notes

A0.5 SPEC should decide:

- the final permission-manifest file layout and schema version;
- how permission manifests compose with the A0a host capability matrix;
- which action classes are critical versus best-effort;
- which setup flows may request broader permissions;
- the exact recovery artifact schema for partial mutations;
- how project-profile secret resolution from A6 plugs into the secret-scope vocabulary.

Any addition to secret scope, mutation scope, or failure class enums is a behavior contract. Treat it as ask-tier review unless it is a non-runtime documentation clarification.

## Carryover

- A0.5 composes this model with A0a, A0b, and A0d into the v2 SPEC.
- A0.6 implements manifest validation and CI/pre-commit gates.
- A6 defines project-profile secret migration and precedence.
- Release-substrate leaves keep `_shared/contracts/release-tf-push.md` as the v1 operational contract until v2 release roles exist.
