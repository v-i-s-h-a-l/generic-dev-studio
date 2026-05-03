---
name: Host Adapter Specification
description: Authoritative guide for authoring a host adapter — files to ship, capabilities to declare, and conformance requirements to pass.
type: reference
---

# Host Adapter Specification

A **host adapter** packages the studio's canonical content for a specific AI coding agent (Claude Code, Codex, Gemini CLI, etc.). This document is the authoritative guide for adapter authors. Once your adapter passes conformance, Achilles and Argus run on your host without modification.

## Files an adapter must ship

| File | Location | Purpose |
|---|---|---|
| `capabilities.yaml` | `.<host>/capabilities.yaml` | Machine-readable manifest declaring what the host can do. |
| Root instruction file | `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, etc. | Host-native entry point; points at or symlinks canonical content. |
| Hook config | `.<host>/hooks.json` (or equivalent) | Wires canonical hook scripts into the host's hook system. |
| `INSTALL.md` | `.<host>/INSTALL.md` | Human-readable setup steps for adapter users. |

Canonical content (`skills/`, `agents/`, `commands/`, hook scripts) lives at the repo root. Adapters reference or symlink it — they never copy it.

## Capability manifest (`capabilities.yaml`)

Every adapter ships a `capabilities.yaml` with exactly these six fields:

```yaml
# All six fields are required. No defaults applied by the runtime.
supports_hooks: <bool>           # Does the host fire pre/post-session hooks?
spawn_command: "<string>"        # Shell command to invoke a new worker session.
block_for_event_strategy: <str>  # How the host blocks waiting for an event: "tail" | "poll" | "none"
tool_dialect: <str>              # Tool-name vocabulary: "claude" | "openai" | "gemini"
sandbox_profile: <str>           # Isolation level: "none" | "host-native" | "workspace-write" | "full"
secret_scope: <str>              # Secret visibility: "inherit-env" | "cwd-only" | "none"
```

### Field semantics

**`sandbox_profile`** — levels form an ordered scale from least to most restrictive:

| Value | Meaning |
|---|---|
| `none` | No isolation — full host env inherited. |
| `host-native` | Host's default sandbox (e.g. Claude Code's built-in permission system). |
| `workspace-write` | Write access to CWD + `~/.dev-studio/**`; no broader filesystem writes. The adapter install guide must document how the host materializes that writable root. |
| `full` | Fully isolated container; no network, no home dir, explicit allow-list only. |

**`secret_scope`** — where secrets are visible inside a worker session:

| Value | Meaning |
|---|---|
| `inherit-env` | Worker inherits the caller's full environment (including `ANTHROPIC_API_KEY`, etc.). |
| `cwd-only` | Only secrets declared in `.env` or equivalent CWD-scoped files. |
| `none` | No secrets injected; worker must not need them. |

## Security floor

These constraints are enforced by `scripts/lint-host-agnostic.sh` (H6) and verified by `scripts/test-host.sh` (H10). An adapter that fails the security floor is rejected at lint time; no workaround is provided.

### Achilles adapters (worker — reads files, writes debriefs, runs git)

```
sandbox_profile ∈ {workspace-write, full}     # NOT none, NOT host-native
secret_scope ∈ {cwd-only, none}               # NOT inherit-env
```

**Why:** Achilles executes untrusted code paths (fixture runs, test gates). `host-native` is insufficient because its boundaries aren't machine-checkable. `inherit-env` exposes API keys to anything the worker invokes, including arbitrary test fixtures.

### Argus adapters (reviewer — reads diffs, emits verdicts)

```
secret_scope = none
```

**Why:** Argus consumes diffs and emits verdicts. It never calls an external API, reads user credentials, or writes to cloud services. Injecting any secret into an Argus session is unnecessary surface — a future prompt-injection in a diff could exfiltrate it.

### PR reviewer profiles (Forge gate — reads PR payloads, emits verdicts)

PR review gates use dedicated reviewer profiles (`reviewer_profile: true`), not
normal worker/reference adapters. A reviewer profile must declare
`secret_scope: none`, force no-prompt headless execution, and keep the session
read-only unless a narrow auto-fix path is explicitly designed later.

Claude Code 2.1.126 auth is coupled to `HOME` even when `CLAUDE_CONFIG_DIR`
points at a dedicated profile. Claude-based reviewer profiles therefore run
with `HOME=${CLAUDE_REVIEWER_HOME:-<login-home>}` and
`CLAUDE_CONFIG_DIR=${CLAUDE_REVIEWER_CONFIG_DIR:-$HOME/.claude-reviewer}`.
For fleet nodes, set `CLAUDE_REVIEWER_HOME` to a locked-down reviewer account
home that contains no GitHub tokens or project secrets. Codex-based reviewers
keep using scratch `HOME` plus `CODEX_HOME`.

Do not make a normal worker profile eligible by relaxing the gate. Add a
dedicated `<host>-reviewer` adapter with its own manifest and enforcement.

The reviewer-profile primitive is not PR-only. Any cross-host review used by
field agents (worker, planner/architect, qa-engineer, flow-tester,
release-manager, perf) must route through this same smoke-gated profile layer
or a v2 successor with the same contract, not through hand-written raw host
commands. The contract is: host auth roots, no-secret env scrubbing, MCP
isolation, sandbox-readable payload handoff, and startup-failure diagnostics
are centralized. Emergency/debug-only override is
`STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1`; use must be user-controlled and
recorded in the review artifact. See `CLAUDE.md` §Cross-host phase review for
the workflow rule that consumes this adapter contract.

### Env-scrub at reviewer dispatch

`scripts/dispatch-review.sh` enforces the reviewer floor at spawn time by env-scrubbing the subprocess. Only PATH/HOME/LANG/USER, the host plugin-root, and explicit task-context vars cross the boundary; `ANTHROPIC_API_KEY`, `GH_TOKEN`/`GITHUB_TOKEN`, and arbitrary inherited env are dropped. The host CLI re-authenticates from its own keychain inside the spawned session.

```bash
env -i \
  PATH="$PATH" HOME="$HOME" LANG="${LANG:-C.UTF-8}" USER="${USER:-}" \
  STUDIO_HOST="$HOST" \
  CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}" \
  CODEX_PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-}" \
  TASK_ID="$TASK_ID" STAGE="$STAGE" \
  ARGUS_IDEMPOTENCY_KEY="$IDEM_KEY" \
  ACHILLES_WORKTREE="$WORKTREE" \
  ACHILLES_BASE_BRANCH="$BASE_BRANCH" \
  TASK_SIZE="$SIZE" \
  "${spawn_argv[@]}" "/dev-studio reviewer $STAGE $TASK_ID"
```

`.netrc` is filesystem-resident, not env-resident, so env-scrub alone doesn't isolate it — the adapter's `sandbox_profile` is responsible for that boundary (Codex's `workspace-write` keeps `~/.netrc` out of the worker's view; Claude Code's `host-native` relies on the documented reference-host exemption).

### Claude Code reference host

Claude Code (`.claude-plugin/capabilities.yaml`) declares `host-native` + `inherit-env`. This violates the worker security floor. The reference host is explicitly exempted because it is the primary development environment where the security constraints are enforced by human oversight rather than mechanical isolation. **Do not use the reference host's values as a template for new adapters.**

## Host preflight

Worker-capable hosts must prove GitHub auth parity before any task work that
can fetch, resolve commits, push, or verify private-repo changes. The studio
uses `scripts/host-preflight.sh <host> <repo-root>` as the shared gate. It
requires both:

- `gh auth status` succeeds through the normalized login `HOME` used for
  studio GitHub operations.
- `git ls-remote --exit-code <project-origin> HEAD` succeeds, which exercises
  the Git credential helper, ssh-agent, or keychain path that later
  commit-resolution and fetch steps depend on, also through the normalized
  login `HOME` when the caller started under a synthetic host home.

Adapters must document how the host receives the same credential surface as
the reference host. Codex chain-runner sessions launch with the user's login
`HOME`, so `gh`, the Git credential helper, `.ssh`, and keychain-backed SSH
agents match normal terminal/Claude sessions. Parent-side scripts that own
GitHub mutations normalize synthetic Codex `HOME` values to the login `HOME`
per command; `STUDIO_BYPASS_PARENT_HOME_FLIP=1` preserves caller `HOME` for
intentional isolation tests. Do not inject tokens into the repo. The
user-controlled emergency bypass for the preflight gate is
`STUDIO_BYPASS_GITHUB_AUTH_PREFLIGHT=1`; bypass use is loud and should be
reserved for deliberate recovery.

## Conformance test

Every adapter must pass `scripts/test-host.sh <host-name>` before claiming support. The harness runs four tasks:

1. **XS trivial edit** — single-file edit, LSP gate only.
2. **M multi-file with build gate** — full build gate + Argus dispatch.
3. **TDD red-green-refactor** — test-first flow + Argus spec-compliance.
4. **Cross-host handoff** — Achilles on host A, Argus on host B; validates `handoff.schema.json` across hosts.

The failure-mode floor also verifies GitHub auth preflight wiring and canonical
Swift package test invocation for nested local-package graphs. A host cannot
claim conformance if a missing credential-helper path or wrong package root
would only be discovered after work starts.

`test-host.sh` is implemented in H10. Adapters authored before H10 lands should include a `conformance: pending` note in `capabilities.yaml`; after H10 ships, `conformance: pending` is a lint error.

## Adding a new adapter (step-by-step)

1. Add a row to `hosts/registry.yaml` with: `display_name`, `detect_binary` (CLI name on PATH), `global_skill_dir`, `project_skill_dir`, `routing_file`, `routing_walks_parents`, `tool_dialect`, and `status: provisional`. The `detect_binary` field enables `sync-host-skills.sh --all` to auto-detect whether this host is installed; `status: provisional` marks the entry as registry-only (no adapter dir yet). This alone is enough for skills declaring `hosts: all` to be symlinked into the host's skill dir on machines where the binary is installed.
2. Create `.<host>/` directory at the repo root.
3. Write `.<host>/capabilities.yaml` with all six required fields.
4. Write `.<host>/INSTALL.md` covering: symlink setup, hook-config pointer, root-instruction-file creation.
5. Write or symlink the host-native root instruction file (`AGENTS.md`, `GEMINI.md`, etc.) at the repo root. Content: one paragraph describing the studio + a pointer to `CLAUDE.md` for the canonical instructions.
6. Wire hooks: copy or adapt `hooks/session-start.sh` into the host's hook-config format. See `hooks/` for canonical scripts.
7. Run `scripts/lint-host-agnostic.sh` — fix any security-floor violations.
8. Run `scripts/test-host.sh <host-name>` — all four tasks must PASS.
9. Update `status` in `hosts/registry.yaml` from `provisional` to `adapted`.
10. Add the host to the conformance matrix table in `ARCHITECTURE.md §Host-agnosticism`.
