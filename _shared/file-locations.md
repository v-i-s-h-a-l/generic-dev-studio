# Shared: File Locations

## Project Slug

Compute once at startup as the basename of the main repo's git toplevel:

```bash
PROJECT=$(basename "$(git -C <repo-root> rev-parse --show-toplevel)")
```

For the Turnip iOS repo this resolves to `turnip-ios`.

## Canonical Roots

All agents read and write under exactly two roots — both inside `~/.dev-studio/` so a single `Read/Write/Edit(~/.dev-studio/**)` allowlist covers everything without permission prompts:

| Root | Scope | Contents |
|---|---|---|
| `~/.dev-studio/<project>/` | Per-project | Worktrees, plans, per-project derived-data, per-project locks, logs |
| `~/.dev-studio/.runtime/` | Cross-project (global) | Fleet inbox (`achilles-inbox/`), test-slot semaphore (`locks/test-slots/`), push queue (`state/push-queue.jsonl`) |

**Never write outside these two roots.** Specifically: never use `~/.claude/` for runtime state — it's the agent's own config dir, outside the allowlist by design. The only `~/.claude/` paths agents may *read* are `~/.claude/secrets/` (narrow allow) and `~/.claude/projects/<slug>/memory/` (Claude Code's own auto-managed area).

When introducing a new artifact type, place it under one of the two canonical roots — extend `.runtime/` for global state, `<project>/` for project-scoped state.

## File Locations

| Artifact | Path |
|---|---|
| Root | `~/.dev-studio/<project>/` |
| Master plan | `~/.dev-studio/<project>/plans/chanakya-master.md` |
| Task briefs | `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md` |
| Debrief inbox | `~/.dev-studio/<project>/plans/chanakya-inbox/` |
| Processed debriefs | `~/.dev-studio/<project>/plans/chanakya-inbox/processed/` |
| Test-case artifacts | `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` |
| User test manifest | `~/.dev-studio/<project>/plans/user-testing.md` |
| Test-flow rounds | `~/.dev-studio/<project>/plans/user-testing-rounds/user-testing-round<N>.md` |
| Journey map (optional) | `~/.dev-studio/<project>/journey-map.md` |
| Worktrees | `~/.dev-studio/<project>/worktrees/<task-id>/` |
| Locks | `~/.dev-studio/<project>/locks/` |
| Per-task DerivedData | `/tmp/derived-data/<task-id>/` |
| Project memory | `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/` |
| Event log | `<project-memory>/events/<YYYY-MM-DD>.jsonl` |
| Event offset marker | `<project-memory>/events_offset.md` |
| Review files | `<project-memory>/reviews/review_<task-id>.md` |
| Review archive | `<project-memory>/reviews/archive/` |
| Push queue | `~/.dev-studio/.runtime/state/push-queue.jsonl` |
| Test-slot semaphore | `~/.dev-studio/.runtime/locks/test-slots/` |
| Argus result bundles | `/tmp/argus-<task-id>.xcresult` |
