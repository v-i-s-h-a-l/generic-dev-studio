---
name: Cleanup Policy
description: Artifact ownership table, retention tiers, and compact extension spec for all agents.
type: reference
---

# Shared: Cleanup Policy

Ownership table, retention tiers, and compact extension spec for all agents.

---

## Ownership Table

| Artifact | Owner | Trigger |
|---|---|---|
| `.argus-running` marker | Argus (trap) | Removed on exit (success or failure) |
| Test-slot files (`~/.dev-studio/.runtime/locks/test-slots/slot-N/`) | Argus (trap) | Released when test phase exits |
| Result bundle (approve) | Argus | Deleted immediately after review completes |
| Result bundle (flag) | Chanakya | Deleted on `review_approved` event (after review file archived) |
| Result bundle (block) | Chanakya | Retained 48h; compact sweeps after |
| Review file (`reviews/review_<task-id>.md`) | Chanakya | Archived to `reviews/archive/` on `task_verified` event |
| Achilles worktree | Achilles | Removed after successful merge (Step 9) |
| Achilles DerivedData | Achilles | Removed after successful merge (Step 9) |
| Event log files | Chanakya compact | Gzip >7 days; delete >30 days |
| Review archive entries | Chanakya compact | Delete >30 days |
| Push queue entries | Chanakya compact | Delete >7 days |
| Stale markers (any PID dead or age >24h) | Chanakya compact | Remove |
| Orphaned `/tmp/argus-*.xcresult` | Chanakya compact | Delete if no matching active task |
| Orphaned DerivedData (worktree gone) | Chanakya compact | Delete |
| `.playwright-mcp/` gitignored telemetry + known stray dumps | Chanakya compact | `git clean -fdX -- .playwright-mcp/`; strays only if untracked |
| Worker `.lock` dir | Worker (trap) | Removed on EXIT/INT/TERM |
| Worker `busy` marker | Worker | Removed after each task; on shutdown |
| Worker `done/<ts>-<id>.task` | Worker (boot sweep) | Auto-pruned >7 days on every worker boot |
| Worker `inbox/`, `rescue/` | Operator | `rescue/` left for manual retry; `fleet-cleanup.sh --all` for teardown |
| Worker `rescue/<task-id>-stuck.md` | Operator | Written by worker on rc=0 + missing debrief; captures flags + log tail |
| Worker `worker.log` | `fleet-cleanup.sh` | Rotated to `.1` when >5MB on soft sweep |
| Stale worker `.lock` (PID dead OR heartbeat >180s) | `fleet-cleanup.sh` (soft) | Cleared on between-session sweep |
| Studio v2 iOS result bundles/logs/tmp | `studio-ios-artifact-janitor.sh` | Passed runs delete after summary extraction; failed/blocking runs retain by TTL |
| Studio v2 iOS DerivedData | Chain runner / iOS janitor | Preserved during the chain; cleaned at chain completion or after failure TTL |
| Studio v2 iOS retention records | `studio-ios-artifact-janitor.sh` | Private root metadata under `retention/`; swept with the artifacts it describes |
| Studio v2 iOS cache quarantine | `xcode-operation` + iOS janitor | Metadata mismatch/cache-poisoning signals move evidence under `quarantine/` for TTL cleanup |

---

## Retention Tiers

### Tier 0 — Immediate (on success/exit)
- `.argus-running` marker
- Test-slot file
- Result bundle for approved reviews

### Tier 1 — Event-triggered (by Chanakya)
- Review file: archive on `task_verified`
- Result bundle for flagged reviews: delete on `review_approved`

### Tier 2 — 48-hour retention (failure paths)
On any block or fail event, **all** associated artifacts are retained for 48h:
- Result bundle (`/tmp/argus-<task-id>.xcresult`)
- Argus review file (`reviews/review_<task-id>.md`)
- Achilles worktree (if merge failed)
- Achilles DerivedData (if build/merge failed)

Chanakya compact only eagerly compacts success paths. Failure-path artifacts survive until either:
- 48h elapses, OR
- The user manually resolves (the task reaches `verified` status)

### Tier 3 — Time-based rotation (compact sweep)
| Artifact | Gzip after | Delete after |
|---|---|---|
| Event log files | 7 days | 30 days |
| Review archive entries | — | 30 days |
| Push queue entries | — | 7 days |
| Failure-path artifacts (xcresult, worktree, DerivedData) | — | 48h |

### Studio v2 iOS retention classes

Scoped iOS profile operations write a private retention record next to the
artifact root after the operation summary is written. Telemetry emitted by the
janitor is redacted: it reports counts, bytes, disk thresholds, and root hashes,
not raw private paths.

| Class | Trigger | Default handling |
|---|---|---|
| `pass-summary-only` | Build/test exits 0 | Delete result bundle, log, and tmp path after summary extraction. Keep DerivedData until chain completion. |
| `pass-short-retain` | Explicit short-retain override | Keep artifacts for 24h, compress large logs/results when configured. |
| `failed-retain` | Build/test exits non-zero | Retain artifacts for 48h by default; compress large retained logs/results. |
| `blocked-retain` | Caller marks the operation blocked | Retain artifacts for 48h by default. |
| `aborted-retain` | Caller marks the operation aborted | Retain artifacts for 24h by default. |
| `debug-pinned` | `STUDIO_IOS_DEBUG_RETAIN=1` | Requires owner, reason, and expiry via `STUDIO_IOS_DEBUG_RETAIN_*`; unbounded pins are rejected. |
| `release-retain` | Release/TestFlight operation | Retain for 30d by default unless a stricter release policy applies. |
| `cache-quarantined` | Metadata mismatch or cache-poisoning signal | Move cache evidence under `quarantine/`; retain 7d by default instead of deleting immediately. |

TTL defaults are configurable with `STUDIO_IOS_ARTIFACT_*_TTL_*` environment
variables. `STUDIO_IOS_ARTIFACT_MIN_FREE_KB` and
`STUDIO_IOS_ARTIFACT_MIN_FREE_PCT` make janitor mutation refuse with redacted
`refused_disk_pressure` telemetry when the current volume is below the safety
floor.

---

## Argus `.argus-running` Marker

Argus writes `.argus-running` to the worktree root at start and removes it at exit:

```bash
MARKER="$WORKTREE/.argus-running"
echo "$$:$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT INT TERM

# ... review work ...

rm -f "$MARKER"
trap - EXIT INT TERM
```

**Achilles respects this marker:** `.argus-running` remains Argus-owned cleanup state, but it is no longer a polling gate. `dispatch-review.sh` owns the wait window, emits `review_timeout` if the verdict never arrives, and kills the spawned review on timeout. Achilles should not busy-wait on the marker before merge cleanup.

---

## Chanakya Compact Extension (`--sweep-artifacts`)

The `--sweep-artifacts` flag (default on) extends compact with artifact cleanup. Run as part of every `compact` invocation unless `--no-sweep-artifacts` is passed.

### Sweep steps

1. **Event log rotation:**
   ```bash
   EVENTS_DIR="$PROJECT_MEMORY/events"
   # Gzip files older than 7 days
   find "$EVENTS_DIR" -name "*.jsonl" -mtime +7 -exec gzip {} \;
   # Delete gzipped files older than 30 days
   find "$EVENTS_DIR" -name "*.jsonl.gz" -mtime +30 -delete
   ```

2. **Review archive pruning:**
   ```bash
   ARCHIVE_DIR="$PROJECT_MEMORY/reviews/archive"
   find "$ARCHIVE_DIR" -name "review_*.md" -mtime +30 -delete
   ```

   Also wipe the Step 0E3 edit-detection markers so a re-edit of an already-emitted brief or debrief can emit again:
   ```bash
   rm -f "$PROJECT_MEMORY/brief_edit_seen.txt" "$PROJECT_MEMORY/debrief_seen.txt"
   ```

3. **Stale marker cleanup:**
   - Scan all `.argus-running` markers in `~/.dev-studio/<project>/worktrees/*/`:
     - Read PID from file
     - If `! kill -0 <pid> 2>/dev/null` (PID dead) OR age >24h → remove marker
   - Scan `~/.dev-studio/.runtime/locks/test-slots/slot-*/pid`:
     - Same PID/age logic → remove slot directory

4. **Orphaned result bundles:**
   ```bash
   # Find all argus xcresult bundles
   for bundle in /tmp/argus-*.xcresult; do
     TASK=$(basename "$bundle" | sed 's/argus-//' | sed 's/.xcresult//')
     # Check if task is active in master plan
     if ! grep -q "^- ID: $TASK" "$MASTER_PLAN"; then
       rm -rf "$bundle"
     fi
   done
   ```

5. **Orphaned DerivedData:**
   ```bash
   for dd in /tmp/derived-data/*/; do
     TASK=$(basename "$dd")
     WORKTREE="$HOME/.dev-studio/$PROJECT/worktrees/$TASK"
     if [ ! -d "$WORKTREE" ] && [ ! -d "$HOME/.dev-studio/$PROJECT/worktrees/$TASK" ]; then
       # Only delete if not a failure-path artifact still within 48h
       AGE_S=$(( $(date +%s) - $(stat -f %m "$dd" 2>/dev/null || echo 0) ))
       if [ "$AGE_S" -gt 172800 ]; then  # 48h = 172800s
         rm -rf "$dd"
       fi
     fi
   done
   ```

6. **Playwright MCP telemetry cleanup:**
   ```bash
   # Playwright MCP writes per-session artifacts (console-*.log, page-*.yml, etc.)
   # into whatever CWD the MCP is launched from — the user's project repo. Files
   # land as untracked, pollute git status, and accumulate on disk forever.
   #
   # .playwright-mcp/ may ALSO contain deliberately tracked assets (committed
   # screenshots, design references). A naïve rm -rf would wipe real user work.
   # git clean -fdX with capital X removes ONLY gitignored files — tracked files
   # are never touched. Scoped path (-- .playwright-mcp/) prevents blast radius
   # outside that directory.
   REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
   if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.playwright-mcp" ]; then
     git -C "$REPO_ROOT" clean -fdX -- .playwright-mcp/ 2>/dev/null || true
   fi

   # Known stray top-level dumps written outside .playwright-mcp/. Delete only
   # when untracked (git ls-files --error-unmatch returns non-zero for untracked).
   if [ -n "$REPO_ROOT" ]; then
     for stray in "$REPO_ROOT/notes_panel.yml"; do
       if [ -f "$stray" ] && ! git -C "$REPO_ROOT" ls-files --error-unmatch "$stray" >/dev/null 2>&1; then
         rm -f "$stray"
       fi
     done
   fi
   ```

   **Precondition:** the repo's `.gitignore` must include `.playwright-mcp/` for the sweep to find anything. Without it, the sweep is a safe no-op. Recommend adding the pattern once per repo during onboarding (see README).

7. **Push queue cleanup:**
   ```bash
   . "$(git rev-parse --show-toplevel)/scripts/lib-paths.sh" 2>/dev/null \
     || . ~/.claude/skills/scripts/lib-paths.sh
   PUSH_FILE=$(resolve_push_queue)
   if [ -f "$PUSH_FILE" ]; then
     CUTOFF=$(date -v -7d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "7 days ago" -u +%Y-%m-%dT%H:%M:%SZ)
     # Filter out entries older than 7 days (awk or python one-liner)
     python3 -c "
import sys, json
cutoff = '$CUTOFF'
for line in open('$PUSH_FILE'):
    try:
        e = json.loads(line)
        if e.get('ts','') >= cutoff:
            sys.stdout.write(line)
    except: pass
" > /tmp/push-queue-filtered.jsonl && mv /tmp/push-queue-filtered.jsonl "$PUSH_FILE"
   fi
   ```

8. **Studio v2 iOS artifact cleanup:**
   ```bash
   scripts/studio-ios-artifact-janitor.sh sweep --base "$TMPDIR/studio-ios-artifacts" --json
   scripts/studio-ios-artifact-janitor.sh sweep --base "$PROJECT_MEMORY/chain-runs/<run>/ios-artifacts" --json
   ```

   The chain runner invokes this sweep before new dispatch and runs
   `complete-chain` for each completed chain's scoped iOS root. Success paths
   delete the root once no pins or retained failure records remain; failure and
   blocked paths stay until their retention TTL expires.

### Compact report line (extended)

After sweep-artifacts runs, append to the compact report:

```
Swept artifacts: rotated N event files (gzip, X KB), freed Y GB DerivedData,
  removed M orphaned xcresult bundles, pruned P archive entries >30d,
  cleared Q stale markers, deleted R Playwright MCP artifacts.
```

---

## `--auto-compact` Flag

When `/chanakya compact --auto-compact` is invoked, Chanakya schedules a nightly compact run. The expected schedule is **03:00 local time** daily.

**v1 implementation:** document only. The user configures cron:

```bash
# Add to crontab (crontab -e):
0 3 * * * cd <repo-root> && claude --print "/chanakya compact --sweep-artifacts" >> ~/.dev-studio/<project>/logs/compact.log 2>&1
```

Chanakya will print these instructions when `--auto-compact` is passed. No runtime cron management by the agent.

**Future:** v2 will use the `CronCreate` MCP to register this automatically.

---

## Chanakya Event-Triggered Cleanup Hooks

These run inside Chanakya's inbox sweep (Step 0) when the corresponding events appear in the event log:

| Event | Action |
|---|---|
| `task_verified` | Archive `review_<task-id>.md` to `reviews/archive/` if it exists |
| `review_approved` | Delete `/tmp/argus-<task-id>.xcresult` if it exists |
| `task_completed` | Commit current event log offset to `events_offset.md` |
