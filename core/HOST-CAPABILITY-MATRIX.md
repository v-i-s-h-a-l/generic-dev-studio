---
name: Host Capability Matrix
description: A0a substrate matrix for gating Studio v2 behavior across Claude Code, Codex CLI, Gemini CLI, and Ollama.
type: reference
---

# Host Capability Matrix

This is the A0a input for #444. It defines what Studio v2 may assume from each
host before the A0.5 `SPEC.md` locks the substrate. The machine-readable source
is `core/host-capability-matrix.yaml`; this file explains the policy.

## Load-bearing floor

Studio v2 load-bearing paths may assume only:

- repo file I/O and runtime artifact I/O under `~/.dev-studio/**`
- a POSIX shell or equivalent command runner
- an explicit instruction file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, or a
  wrapper-specified equivalent)
- deterministic handoff artifacts
- JSON Schema validation for cross-agent contracts

They must not require:

- SessionStart hooks
- host-native subagents
- slash-command-only dispatch
- host-specific tool names
- inherited secret environments

Hooks, slash commands, host subagents, and native skill systems are allowed as
ergonomic adapters. They are never the only path.

## Status vocabulary

| Status | Meaning |
|---|---|
| `supported` | Usable by Studio v2 load-bearing paths after adapter conformance. |
| `provisional` | Host surface exists or is planned, but Studio adapter/conformance is incomplete. |
| `unsupported` | Known not to satisfy the dimension without an external wrapper or future adapter work. |
| `unknown` | Insufficient evidence for a substrate claim; callers must fail explicitly or choose a supported host. |

## Matrix

| Host | Registry status | Tool calling | Subagents | Skills | FS + shell | Hooks | Secrets | Worker | Reviewer | v2 gate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Claude Code | `adapted` | supported | supported | supported | supported | supported | `inherit-env` | provisional | supported | Reference interactive host; do not copy its worker security profile. |
| Codex CLI | `adapted` | supported | unsupported | supported | supported | supported | `cwd-only` | supported | supported | Primary non-Claude proof host. |
| Gemini CLI | `provisional` | provisional | unknown | provisional | provisional | unknown | unknown | unknown | unknown | Candidate only until adapter, security floor, and conformance land. |
| Ollama | absent | provisional | unsupported | unsupported | unsupported | unsupported | `none` | unsupported | unsupported | Treat as model provider, not a coding host, unless wrapped by an adapter. |

## Feature gates

**Tool calling.** Required for autonomous worker/reviewer execution. If absent
or unknown, the host may only run read-only prose planning through an explicit
wrapper.

**Subagent spawning.** Never load-bearing. Use process-level handoff artifacts
and chain-runner dispatch instead.

**Skill loading.** Host-native skill mechanics may be used when available, but
the substrate must also support repo-vendored prompt artifacts loaded by path.

**Filesystem access.** Worker-capable hosts must allow repo reads/writes plus
`~/.dev-studio/**` runtime artifacts. Reviewer profiles should be read-only
unless a narrow auto-fix path is designed later.

**Long-running state.** Never kept inside host session memory. Durable state
lives in event logs, summary artifacts, and chain-runner envelopes.

**Hooks.** Optional accelerator only. Required checks must also be invocable by
scripts, pre-commit, or CI.

**Secret isolation.** Worker-capable hosts must avoid inherited full env.
Reviewer-capable hosts must receive no secrets.

## Host notes

**Claude Code.** The reference interactive host is adapted today, but its normal
worker profile declares `sandbox_profile: host-native` and `secret_scope:
inherit-env`. That is acceptable only for the human-supervised reference path.
The Claude reviewer profile remains separate and no-secret. V2 cannot depend on
Claude subagents, slash commands, or SessionStart injection.

**Codex CLI.** Codex is the current non-Claude proof host. Its worker profile
uses `workspace-write` with `cwd-only` secrets, and its reviewer profile is
read-only/no-secret. V2 multi-agent work should continue to use chain-runner
artifacts and scripts rather than host-native subagents.

**Gemini CLI.** Gemini is listed in `hosts/registry.yaml` as provisional. Its
public CLI docs describe extensions, custom commands, MCP, sandbox flags, and
tool execution surfaces, but Studio does not yet ship a `.gemini/` adapter or
security-floor manifest. Until those land, Gemini support is an explicit
unknown for worker/reviewer dispatch.

**Ollama.** Ollama exposes a local API and tool-calling support for compatible
models, but it is not itself a coding-agent host with repo filesystem/shell
control, skills, hooks, or chain-runner semantics. V2 should model Ollama as a
provider/backend unless a separate adapter wrapper supplies the missing host
surface. Tool-calling must be gated by selected model capability.

## A0.5 inputs

A0.5 `SPEC.md` should carry these requirements forward:

- unsupported or unknown host combinations fail loudly with host and missing
  capability fields
- at least Claude Code plus one non-Claude host must exercise the same manager
  artifact contracts before A7 proof-of-life
- `hosts/registry.yaml`, per-host `capabilities.yaml`, and this matrix must not
  drift on supported host claims
- model names resolve through `_shared/schemas/model-catalog.yaml`; host
  capability gates do not hardcode model defaults

## Sources

Local sources: `hosts/registry.yaml`, `hosts/ADAPTER-SPEC.md`, the existing
`.claude-*` and `.codex*` capability manifests, and
`_shared/schemas/model-catalog.yaml`.

External sources checked on 2026-05-03: Gemini CLI docs for extensions and CLI
commands, and Ollama docs for tool calling and the API.
