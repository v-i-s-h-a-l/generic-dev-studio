# Shared: File Locations

## Project Slug

Compute once at startup as the basename of the main repo's git toplevel:

```bash
PROJECT=$(basename "$(git -C <repo-root> rev-parse --show-toplevel)")
```

For the Turnip iOS repo this resolves to `turnip-ios`.

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
| Push queue | `~/.claude/state/push-queue.jsonl` |
| Test-slot semaphore | `~/.claude/locks/test-slots/` |
| Argus result bundles | `/tmp/argus-<task-id>.xcresult` |
