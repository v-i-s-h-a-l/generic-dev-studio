# Checkpoint Context

Goal: define and validate the compact checkpoint artifact contract.

Current state: the session has a scoped issue, a clean start envelope, and a
checkpoint fixture that proves only `manifest.json` and this `context.md` are
needed before lazy loading.

Next action: validate schemas and inspect `next-steps.json` only if the resumed
worker needs the exact remaining action list.

Lazy-load hints:

- Load `state.json` for branch, commit, dirty-tree, and role-owned state.
- Load `next-steps.json` when choosing the next concrete action.
- Load `evidence.json` only when a claim needs command, diff, review, or test evidence.
- Read `telemetry.jsonl` for budget warnings, drift checks, usefulness, and v1 tuning signals.

Forbidden content: this file is a compact summary. It is not a transcript,
prompt history, chat log, or command-output dump.
