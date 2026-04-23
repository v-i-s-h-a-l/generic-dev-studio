#!/usr/bin/env bash
# achilles-refresh-base.sh — Step 8.4 of the Achilles task mode.
#
# Before handing off to Argus (Step 8.5), refresh the worktree's base branch
# if drift against `origin/<base>` exceeds a threshold. Prevents Argus from
# blocking on base-staleness — the cheap round-trip Achilles can avoid.
#
# Behavior:
#   1. `git fetch origin <base>` (best-effort; network failure → no-op, exit 0).
#   2. Count `rev-list --count <base-tip>..origin/<base>` — commits the worktree
#      is behind.
#   3. If behind < threshold → no-op, no event, exit 0 (idempotent).
#   4. Otherwise `git merge --no-ff origin/<base>` into the worktree branch.
#      - Merge matches Step 9 convention (task-merge.sh). Rebase is rejected
#        here because it rewrites mid-task commits the debrief references.
#   5. Clean merge → emit `base_refreshed` with `commits_pulled`, exit 0.
#   6. Conflict → abort the merge (leave worktree clean), emit
#      `base_refresh_conflict`, exit 2. Caller surfaces to user; no auto-resolve.
#
# Threshold:
#   $ACHILLES_BASE_REFRESH_THRESHOLD (env), else 2.
#
# Usage:
#   scripts/achilles-refresh-base.sh <task-id> <worktree> <base-branch>
#
# Exit codes:
#   0  fresh or refreshed cleanly (no-op or success)
#   2  merge conflict — caller must block Step 8.5
#   3  missing args / worktree not found

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: achilles-refresh-base.sh <task-id> <worktree> <base-branch>}"
WORKTREE="${2:?worktree required}"
BASE_BRANCH="${3:?base-branch required}"

THRESHOLD="${ACHILLES_BASE_REFRESH_THRESHOLD:-2}"
case "$THRESHOLD" in
  ''|*[!0-9]*)
    printf 'warn: ACHILLES_BASE_REFRESH_THRESHOLD=%s not a non-negative integer; using 2\n' \
      "$THRESHOLD" >&2
    THRESHOLD=2
    ;;
esac

if [ ! -d "$WORKTREE" ]; then
  printf 'error: worktree not found: %s\n' "$WORKTREE" >&2
  exit 3
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN refresh-base task=%s worktree=%s base=%s threshold=%s\n' \
    "$TASK_ID" "$WORKTREE" "$BASE_BRANCH" "$THRESHOLD" >&2
  exit 0
fi

# Best-effort fetch — offline / no-remote is not a failure mode. If the fetch
# is stale, `rev-list` below just sees fewer commits; worst case we let Argus
# catch the staleness, same as today.
git -C "$WORKTREE" fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true

# Commits the worktree's base-branch tip is behind origin. Measure against the
# merge-base of the worktree branch and origin/<base> — we care about whether
# `origin/<base>` has moved forward past the branch point, not whether HEAD
# contains all of origin/<base>.
if ! BEHIND=$(git -C "$WORKTREE" rev-list --count "HEAD..origin/$BASE_BRANCH" 2>/dev/null); then
  # origin ref absent (never fetched / wrong remote) — no-op, let Argus decide.
  exit 0
fi

if [ "$BEHIND" -lt "$THRESHOLD" ]; then
  # Fresh enough. Idempotent no-op — no event (keeps the log signal-dense).
  exit 0
fi

# Attempt the merge. `--no-ff` mirrors Step 9; keeps the refresh visible as a
# distinct commit rather than fast-forwarding over mid-task work.
if git -C "$WORKTREE" merge --no-ff "origin/$BASE_BRANCH" \
     -m "Refresh base: merge origin/$BASE_BRANCH into achilles/$TASK_ID" \
     >/dev/null 2>&1; then
  data=$(printf '{"worktree":"%s","base_branch":"%s","commits_pulled":%s,"threshold":%s}' \
    "$WORKTREE" "$BASE_BRANCH" "$BEHIND" "$THRESHOLD")
  emit_event_keyed achilles task base_refreshed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  printf 'base refreshed: pulled %s commit(s) from origin/%s\n' "$BEHIND" "$BASE_BRANCH" >&2
  exit 0
fi

# Conflict — abort so the worktree is left in a clean state. Caller blocks.
git -C "$WORKTREE" merge --abort >/dev/null 2>&1 || true

# Capture conflicted paths (best-effort; empty array if abort already cleared).
conflicts=$(git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null | \
  awk 'BEGIN{first=1;printf "["} {if(!first)printf ",";printf "\"%s\"",$0;first=0} END{printf "]"}')
: "${conflicts:=[]}"

data=$(printf '{"worktree":"%s","base_branch":"%s","commits_pulled":%s,"threshold":%s,"files":%s}' \
  "$WORKTREE" "$BASE_BRANCH" "$BEHIND" "$THRESHOLD" "$conflicts")
emit_event_keyed achilles task base_refresh_conflict "$TASK_ID" "$data" >/dev/null 2>&1 || true
printf 'error: base refresh conflict merging origin/%s into %s; resolve manually before review\n' \
  "$BASE_BRANCH" "$WORKTREE" >&2
exit 2
