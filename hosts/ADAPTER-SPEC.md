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
| `workspace-write` | Write access to CWD + `~/.dev-studio/**`; no broader filesystem writes. |
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

### Claude Code reference host

Claude Code (`.claude-plugin/capabilities.yaml`) declares `host-native` + `inherit-env`. This violates the Achilles security floor. The reference host is explicitly exempted because it is the primary development environment where the security constraints are enforced by human oversight rather than mechanical isolation. **Do not use the reference host's values as a template for new adapters.**

## Conformance test

Every adapter must pass `scripts/test-host.sh <host-name>` before claiming support. The harness runs four tasks:

1. **XS trivial edit** — single-file edit, LSP gate only.
2. **M multi-file with build gate** — full build gate + Argus dispatch.
3. **TDD red-green-refactor** — test-first flow + Argus spec-compliance.
4. **Cross-host handoff** — Achilles on host A, Argus on host B; validates `handoff.schema.json` across hosts.

`test-host.sh` is implemented in H10. Adapters authored before H10 lands should include a `conformance: pending` note in `capabilities.yaml`; after H10 ships, `conformance: pending` is a lint error.

## Adding a new adapter (step-by-step)

1. Create `.<host>/` directory at the repo root.
2. Write `.<host>/capabilities.yaml` with all six required fields.
3. Write `.<host>/INSTALL.md` covering: symlink setup, hook-config pointer, root-instruction-file creation.
4. Write or symlink the host-native root instruction file (`AGENTS.md`, `GEMINI.md`, etc.) at the repo root. Content: one paragraph describing the studio + a pointer to `CLAUDE.md` for the canonical instructions.
5. Wire hooks: copy or adapt `hooks/session-start.sh` into the host's hook-config format. See `hooks/` for canonical scripts.
6. Run `scripts/lint-host-agnostic.sh` — fix any security-floor violations.
7. Run `scripts/test-host.sh <host-name>` — all four tasks must PASS.
8. Add the host to the conformance matrix table in `ARCHITECTURE.md §Host-agnosticism`.
