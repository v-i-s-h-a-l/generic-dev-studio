# Host conformance harness (H10)

Static fixtures + harness driving `scripts/test-host.sh`. The harness exercises the
**studio's host-agnostic seams** (capability-manifest validation, env-scrub at
dispatch, handoff-envelope schema, security floor, lint refusal) — not the
agents' reasoning. Real Achilles / Argus runs are still gated on actual
TestFlight + brief queues; this layer asserts the substrate they run on.

## Layout

| Path | Purpose |
|---|---|
| `fixtures/<task>/` | Per-task brief + expected debrief / verdict YAML. Read-only inputs. |
| `fixtures/failure-modes/` | Bad inputs that MUST trigger loud refusals. |
| `baselines/claude-code-pre-v1.jsonl` | Recorded event sequence on the reference host before host-agnostic v1. Diff target for Criterion 1 (byte-identical behaviour). |
| `mock-codex/` | Deterministic Codex adapter satisfying `hosts/ADAPTER-SPEC.md`. CI uses this in place of a real `codex exec` invocation. |

## Runtime writes

Harness output (scratch event logs, recorded spawn argv, normalized diffs)
lands under `~/.dev-studio/.runtime/conformance/<run-id>/`. Per CLAUDE.md
runtime-path rule (R3); never under `/tmp` or `~/.claude`.

## Acceptance

- `scripts/test-host.sh claude-code` — reference host, all 4 happy-path tasks
  + 3 failure-mode floors PASS on a clean tree.
- `scripts/test-host.sh codex` — uses the mock-codex shim under this directory
  unless `STUDIO_CODEX_BIN` points at a real `codex` binary. Same task matrix.
- A real Codex run is required before tagging the host-agnostic-workers-v1
  release (issue #88 §Success 2). The mock satisfies CI, not the release gate.
