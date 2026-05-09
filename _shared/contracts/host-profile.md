---
name: Host Profile Contract
description: Schema for host runtime profiles consumed by the host-agnostic runtime resolver.
type: contract
---

# Host Profile Contract

Host profiles describe how the Studio resolves a model host without baking host
rules into consumer scripts. The repo-shipped default profile file lives at
`_shared/host-profiles/default.yaml`.

## File Shape

```yaml
schema_version: 1
kind: host-profiles
default_order:
  - claude
  - codex
profiles:
  <profile-id>:
    host_id: <profile-id>
    binary_path: <command-or-absolute-path>
    auth_home: <resolver-expression>
    github_home: <resolver-expression>
    capabilities:
      - worker
    synthetic_home_behavior: <behavior-id>
    eligibility_smoke_command: <shell-command>
```

`default_order` is `claude,codex`. It is alphabetical and does not encode a
quality preference. Runtime consumers can override ordering with
`STUDIO_AUTO_HOST_ORDER`; this contract only defines the shipped default.

## Profile Fields

| Field | Type | Required | Description |
|---|---|---:|---|
| `host_id` | string | yes | Stable logical host id. It must match the key under `profiles`. |
| `binary_path` | string | yes | CLI command name or absolute binary path used to launch the host. Command names are resolved with `command -v` by consumers. |
| `auth_home` | string | yes | Host credential/config home after resolver expansion. Use `${login_home}` for the real user home, not a synthetic launcher home. |
| `github_home` | string | yes | Home directory used for GitHub CLI and credential-probing git calls. Defaults should normalize synthetic host homes back to `${login_home}`. |
| `capabilities` | array | yes | Non-empty array of supported role capabilities. Allowed values are `worker`, `reviewer`, `planner`, and `perf`. |
| `synthetic_home_behavior` | string | yes | Named behavior that tells consumers how to treat launcher homes such as `.codex-homes`. Behavior names are resolver-owned, not script-owned. |
| `eligibility_smoke_command` | string | yes | Non-mutating command run from the repo root to prove the host can start in the requested profile. It must not require interactive input. |

## Resolver Expressions

The default file uses expression strings instead of machine-local absolute
paths. Consumers expand only the variables they explicitly support.

| Expression | Meaning |
|---|---|
| `${login_home}` | Real account home resolved by `resolve_user_login_home`; never a synthetic host home. |
| `${github_home}` | GitHub home resolved by `resolve_parent_home_for_github`. |
| `${env.NAME}` | Environment variable `NAME`, if present. |
| `${env.NAME:-fallback}` | Environment variable `NAME`, otherwise the fallback expression. |

Consumers must fail loud on an unsupported expression instead of silently
falling back to ambient `HOME`.

## Synthetic Home Behavior Names

| Behavior | Meaning |
|---|---|
| `login-home-runtime` | Runtime and GitHub paths use `${login_home}` when ambient `HOME` is synthetic. |
| `codex-auth-home-runtime` | Runtime and GitHub paths use `${login_home}` when ambient `HOME` is synthetic; Codex auth prefers `CODEX_WORKER_HOME`, then `CODEX_HOME`, then `${login_home}/.codex`. |

## Fully Worked Example

```yaml
schema_version: 1
kind: host-profiles
default_order:
  - claude
  - codex
profiles:
  claude:
    host_id: claude
    binary_path: claude
    auth_home: "${env.CLAUDE_HOME:-${login_home}}"
    github_home: "${github_home}"
    capabilities:
      - worker
      - reviewer
      - planner
      - perf
    synthetic_home_behavior: login-home-runtime
    eligibility_smoke_command: "claude -p --permission-mode dontAsk 'Print STUDIO_HOST_PROFILE_SMOKE=ok'"
```

This resolves the host binary from `PATH`, keeps Claude auth under the real
login home unless `CLAUDE_HOME` is set, and keeps GitHub operations out of a
synthetic host home.

## Validation Expectations

- The YAML file parses with `yq`.
- `profiles.claude` and `profiles.codex` exist in the default file.
- Every profile has exactly the seven required fields above.
- `capabilities` contains only `worker`, `reviewer`, `planner`, and `perf`.
- Consumer migrations stay separate from this contract. Inventory-only notes
  belong in the private analysis artifact for the migration arc.
