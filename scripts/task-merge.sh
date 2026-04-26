#!/usr/bin/env bash
# task-merge.sh — Step 9 of the Achilles task mode.
#
# Serializes the main-checkout merge section across Achilles instances with a
# project-scoped mkdir lock + 30-minute staleness reclaim. The committing
# inside the worktree is safe unlocked (each worktree has its own index) and
# is the caller's responsibility — this script owns only the main-checkout
# block.
#
# Pre-step: stale `.git/index.lock` removal per _shared/primitives/safe-git.md.
# The helper there wraps `git commit`, but the same class of orphan can
# strand `git checkout` + `git merge`, so we clear it the same way and emit
# `stale_index_lock_removed` when we do.
#
# Sequence inside the lock:
#   1. checkout orig-branch
#   2. fetch origin/<orig-branch> (best-effort)
#   3. merge --no-ff achilles/<task-id>
#
# On clean merge: remove worktree, clean DerivedData, emit `task_merged`.
# On conflict: leave worktree + DerivedData intact, emit `merge_conflict`,
# exit 2 — Achilles caller surfaces to the user.
#
# Pre-merge guard (#249 Phase 2): refuses to merge if no debrief is staged
# for this task under `plans/debriefs/`. Closes the silent-merge dark window
# Phase 1's detector observes after the fact. Override with the env opt-in
# `STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF=1` — emits `debrief_missing` with
# `reason=pre_merge_warn` and proceeds. Without override: emits the same
# event with `reason=pre_merge_blocked` and exits 4.
#
# Usage:
#   scripts/task-merge.sh <task-id> <worktree> <orig-branch> [merge-message]
#
# Exit codes:
#   0  merged cleanly
#   2  conflict or other merge failure
#   3  lock wait exceeded (30 min)
#   4  no debrief staged (#249) — set STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF=1 to override

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: task-merge.sh <task-id> <worktree> <orig-branch> [merge-message]}"
WORKTREE="${2:?worktree required}"
ORIG_BRANCH="${3:?orig-branch required}"
MERGE_MSG="${4:-Merge $TASK_ID into $ORIG_BRANCH}"

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

BRANCH="achilles/$TASK_ID"

# Resolve the main repo from the worktree's common git dir — safer than
# asking the caller to pass it; worktrees always know their upstream.
REPO_ROOT=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ -n "$REPO_ROOT" ] && REPO_ROOT=$(dirname "$REPO_ROOT")
[ -z "$REPO_ROOT" ] && { printf 'error: cannot resolve main repo from worktree %s\n' "$WORKTREE" >&2; exit 2; }

PROJECT=$(basename "$REPO_ROOT")
LOCK_ROOT="$(resolve_runtime_global)/merge-lock"
LOCK="$LOCK_ROOT/$PROJECT"
DERIVED=$(resolve_derived_data_for "$TASK_ID")

mkdir -p "$(dirname "$LOCK")" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$(dirname "$LOCK")" >&2; exit 2; }

# DRY-RUN — log the would-be ops and exit clean.
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN git -C %s checkout %s\n' "$REPO_ROOT" "$ORIG_BRANCH" >&2
  printf 'DRY-RUN git -C %s merge --no-ff %s -m "%s"\n' "$REPO_ROOT" "$BRANCH" "$MERGE_MSG" >&2
  printf 'DRY-RUN git worktree remove %s\n' "$WORKTREE" >&2
  printf 'DRY-RUN rm -rf %s\n' "$DERIVED" >&2
  printf 'DRY-RUN git branch -d %s\n' "$BRANCH" >&2
  exit 0
fi

# ---------- Pre-merge: debrief precondition (#249 Phase 2) ----------
#
# Walk plans/debriefs/*.yaml; require an entry whose `legacy_task_id` matches
# this task and is in the canonical staged state (state == "emitted", or
# absent — which reads as emitted per inbox-sweep.md back-compat). This is
# a fail-fast gate run before the lock so a missing-debrief case never
# blocks other Achilles workers.
#
# Strict by default; override with STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF=1 for
# genuine emergencies. Both paths emit `debrief_missing` so the inbox-sweep
# surfacing in /chanakya status stays loud.
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
debrief_staged=0
if [ -n "$DEBRIEFS_DIR" ] && [ -d "$DEBRIEFS_DIR" ] && command -v yq >/dev/null 2>&1; then
  for yaml in "$DEBRIEFS_DIR"/*.yaml; do
    [ -f "$yaml" ] || continue
    legacy=$(yq -r '.legacy_task_id // ""' "$yaml" 2>/dev/null || echo "")
    [ "$legacy" = "$TASK_ID" ] || continue
    state=$(yq -r '.state // "emitted"' "$yaml" 2>/dev/null || echo emitted)
    [ "$state" = "emitted" ] || continue
    debrief_staged=1
    break
  done
fi

if [ "$debrief_staged" -eq 0 ]; then
  if [ "${STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF:-0}" = "1" ]; then
    reason="pre_merge_warn"
  else
    reason="pre_merge_blocked"
  fi
  data=$(printf '{"reason":"%s","branch":"%s"}' "$reason" "$BRANCH")
  emit_event_keyed achilles task debrief_missing "$TASK_ID" "$data" >/dev/null 2>&1 || true
  if [ "$reason" = "pre_merge_blocked" ]; then
    printf 'error: no debrief staged for %s — run scripts/task-emit-debrief.sh (Step 9) before merge.\n' "$TASK_ID" >&2
    printf '       set STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF=1 to merge anyway (emergencies only).\n' >&2
    exit 4
  fi
  printf 'warn: no debrief staged for %s; STUDIO_ALLOW_MERGE_WITHOUT_DEBRIEF=1 set — proceeding.\n' "$TASK_ID" >&2
fi

# ---------- Acquire lock ----------
# 30-minute stale reclaim (merge ops are much shorter than xcodebuild, so
# shorter window than the build lock). 30-minute wait envelope; sleep 5s.
wait_seconds=0
wait_cap=1800
backoff=5
while true; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/pid"
    break
  fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    printf 'warn: stale merge lock (>30m), reclaiming\n' >&2
    rm -rf "$LOCK"
    continue
  fi
  if [ "$wait_seconds" -ge "$wait_cap" ]; then
    printf 'error: merge lock wait exceeded %ss\n' "$wait_cap" >&2
    exit 3
  fi
  sleep "$backoff"
  wait_seconds=$((wait_seconds + backoff))
done

trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ---------- Stale index-lock guard ----------
#
# Mirror safe-git.md — if `.git/index.lock` exists with no live holder,
# remove it and emit `stale_index_lock_removed`. Prevents strand on checkout.
index_lock="$REPO_ROOT/.git/index.lock"
if [ -e "$index_lock" ]; then
  if ! pgrep -f "git .* $REPO_ROOT" >/dev/null 2>&1; then
    rm -f "$index_lock" 2>/dev/null || true
    data=$(printf '{"repo":"%s","caller_skill":"achilles-merge"}' "$REPO_ROOT")
    emit_event_keyed achilles task stale_index_lock_removed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  fi
fi

# ---------- Merge ----------
cd "$REPO_ROOT" || { printf 'error: cd %s failed\n' "$REPO_ROOT" >&2; exit 2; }

git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || {
  printf 'error: git checkout %s failed\n' "$ORIG_BRANCH" >&2
  exit 2
}
# Best-effort fetch — network down or not-yet-pushed branches are fine to
# merge against local tip. Silent on failure.
git fetch origin "$ORIG_BRANCH" >/dev/null 2>&1 || true

if ! git merge --no-ff "$BRANCH" -m "$MERGE_MSG" >/dev/null 2>&1; then
  # Conflict — collect affected files for the event. Leave the repo in its
  # conflicted state so the user can resolve; do not auto-abort (the prose
  # contract was explicit: "Do not force-resolve").
  conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  data=$(printf '{"branch":"%s","files":"%s"}' "$BRANCH" "$conflicted")
  emit_event_keyed achilles task merge_conflict "$TASK_ID" "$data" >/dev/null 2>&1 || true
  printf 'error: merge conflict on %s; resolve manually. DerivedData retained at %s\n' \
    "$BRANCH" "$DERIVED" >&2
  exit 2
fi

MERGE_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

# ---------- Post-merge cleanup (unlocked portion OK to run here too) ----------
# Worktree removal: --force guards against leftover artifacts the user might
# have dropped in the worktree dir. DerivedData is a straight rm -rf.
git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || {
  printf 'warn: git worktree remove %s failed; continuing\n' "$WORKTREE" >&2
}
rm -rf "$DERIVED" 2>/dev/null || true

# Branch is now fully merged into ORIG_BRANCH (merge commit above). -d (not -D)
# refuses if git sees any non-fast-forward state — the happy path always
# succeeds, any refusal surfaces as a warning without losing work.
git branch -d "$BRANCH" >/dev/null 2>&1 || {
  printf 'warn: git branch -d %s refused (not fully merged?); leaving branch alive\n' "$BRANCH" >&2
}

# #154 sentinel — if no review_(approved|flagged|blocked) preceded this merge
# for this task in the current event log, the code-quality gate was skipped
# (silent dispatch failure, manual override, or stage-2 short-circuit). Emit
# argus_gate_skipped with reason=no_verdict_at_merge so the dark window is
# loud rather than dark. XS-trivial diffs that legitimately bypass Argus also
# trip this; readers join with task size to suppress the false positive.
event_log=$(resolve_event_log 2>/dev/null || echo "")
if [ -n "$event_log" ] && [ -f "$event_log" ]; then
  if ! grep -E "\"task\":\"$TASK_ID\".*\"event\":\"review_(approved|flagged|blocked)\"" "$event_log" >/dev/null 2>&1; then
    skip_data=$(printf '{"reason":"no_verdict_at_merge","branch":"%s","merge_sha":"%s"}' "$BRANCH" "$MERGE_SHA")
    emit_event_keyed argus review argus_gate_skipped "$TASK_ID" "$skip_data" >/dev/null 2>&1 || true
  fi
fi

data=$(printf '{"merge_sha":"%s","branch":"%s"}' "$MERGE_SHA" "$BRANCH")
emit_event_keyed achilles task task_merged "$TASK_ID" "$data" >/dev/null 2>&1 || true

printf 'MERGE_SHA=%s\n' "$MERGE_SHA"
