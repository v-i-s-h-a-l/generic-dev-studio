---
name: Dry-Run Pattern
description: Convention every writable mode adopts to expose a --dry-run path that performs reads and computations but replaces writes with log lines. Exit code 0 = would succeed, 2 = dry-run surfaced a problem. Additive flag; never inverts defaults.
type: reference
---

# Dry-Run Pattern

A `--dry-run` path lets a user or agent inspect what a mode would do without committing to writes. Under Phase 2.5 Q6, Achilles `task` mode is the pilot; Phase 2.6 rewrites will adopt the pattern across 30+ modes. Piloting catches contract bugs before broad fan-out.

## Rules

1. **Reads and computations run normally.** A dry-run reads the brief, resolves paths, computes diffs, invokes LSP / static analyzers, consults snapshots — all the usual observational work.
2. **Writes become log lines.** Every write site emits:
   ```
   DRY-RUN write path=<path> bytes=<n> idempotency_key=<key>
   ```
   Where `<path>` is the resolved destination (after `<project>` expansion), `<n>` is `|payload|`, `<key>` is per `idempotency.md`.
3. **Events buffer and print; do not append.** The mode collects events it would emit, prints them at the end under `DRY-RUN events (N):`, then exits. The real event log is untouched.
4. **External side effects are no-ops.** Slack posts, TestFlight uploads, App Store submissions, git mutations: simulated via log line only. Dry-run that touches the network is a broken dry-run.
5. **Exit code taxonomy.**
   - `0` — dry-run ran to completion; would succeed in wet-run.
   - `2` — dry-run surfaced a problem (e.g. missing upstream artifact, ambiguous brief, would block at a gate). Distinct from exit 1 (crash / bug).
6. **Additive flag, never inverts defaults.** `--dry-run` is always opt-in. No "default to dry-run in CI" variant — ambiguity harms more than convenience gains.
7. **Non-write modes say so inline.** Router prose enumerates modes that perform no writes (`status`, `verify` preview, etc.). `--dry-run` on a non-write mode is a no-op success.
8. **Idempotency keys compute the same way.** The key a dry-run logs is byte-identical to the key a wet-run would use on the same inputs. Lets dry-run output be `diff`ed against wet-run artifacts.
9. **Log to stderr for structured lines, stdout for user-facing summary.** A downstream wrapper can pipe stderr through a filter and still let the user see the summary.

## Minimum viable implementation

Every writable mode with `--dry-run`:

```bash
if [ "$DRY_RUN" = "1" ]; then
  printf 'DRY-RUN write path=%s bytes=%d idempotency_key=%s\n' \
    "$target" "$(printf '%s' "$payload" | wc -c)" "$idem_key" >&2
else
  printf '%s' "$payload" > "$target"
  append_event "$agent" "$event" "$task" "$data"
fi
```

End-of-session, if `DRY_RUN=1`:

```bash
printf 'DRY-RUN events (%d):\n' "${#EVENTS[@]}" >&2
for e in "${EVENTS[@]}"; do printf '  %s\n' "$e" >&2; done
printf 'DRY-RUN would succeed\n'
exit 0
```

## Pilot scope — Achilles task mode (Phase 2.5 Commit F)

The task-mode pilot must exercise every writable path the mode has:
- Brief read + claim (no-op; read-only anyway)
- Worktree creation (`git worktree add` — simulated)
- File writes during Step 4 (simulated per-file)
- xcodebuild / LSP (run for real; read-only w.r.t. repo state)
- Argus invocation (invoke Argus with `--dry-run` passthrough — needs Argus support too, or skip + log)
- Merge (simulated — emits `DRY-RUN merge` log line, does not mutate branch)
- Debrief write (simulated)
- Event emissions (buffered)

If Argus does not yet support `--dry-run`, the Achilles pilot skips the Argus step with a `DRY-RUN skip argus` log line and exits with code 0 (a dry-run that cannot exercise one gate is still useful). Argus adoption is part of the 2.6 fan-out.

## What this buys

- Crash-free exploration of a mode's behavior. Users can ask "what would `/achilles task T042` do here?" and get a plan back without committing.
- Test scaffolding. Integration tests can run dry-runs and diff the log against fixtures.
- Remote-orchestration debugging. Operator on a phone can preview a command before sending it.

## Related

- `message-contract.md` — dry-run preserves envelope shape in logs.
- `idempotency.md` — keys match byte-for-byte across dry/wet.
- `patterns/capability-manifest.md` — manifest marks modes that support dry-run.
