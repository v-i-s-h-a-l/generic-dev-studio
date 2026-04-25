#!/usr/bin/env bash
# sweep-janitor.sh [--dry-run] [--all-projects] <subcommand>
#
# Step 0D — stale-artifact sweep. Five independent subcommands:
#
#   worktrees        Prune worktree dirs older than 7 days with no
#                    active-review marker + no live `git worktree` entry.
#   feedback-assets  Prune per-feedback attachment dirs whose parent record
#                    is `state: archived` and older than 30 days.
#   orphan-assets    Prune assets under chanakya-inbox/assets/ not referenced
#                    by any feedback record; 7d mtime grace.
#   scaling-alerts   Line-count feedback/active.md; warn @ 50, block @ 100
#                    (sets feedback_ingest_blocked flag).
#   local-debt       Issue #31 — worktrees whose branch is fully merged into a
#                    protected base (regardless of mtime), DerivedData dirs
#                    under ~/.dev-studio/.runtime/derived-data/ whose worktree
#                    no longer exists, and locks/xcodebuild.lock whose pid
#                    file points at a dead process. PID-gated, not time-gated.
#   all              Run all five in order.
#
# --all-projects iterates list_fleet_projects and re-execs per project. Cannot
# be combined with subcommands that aren't `all` or `local-debt` — those are
# the only sweeps with cross-project meaning.
#
# DRY_RUN=1 (env) or --dry-run flag reports targets without deleting. Every
# unlink is prefix-checked against the project root (or the runtime-global
# derived-data dir for the local-debt path) so a misconfigured resolver can't
# walk off the reservation.
#
# Emits `cleanup_completed` at the end (archived count + freed gigabytes).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

DRY_FLAG=0
ALL_PROJECTS=0
# Order-independent flag parse — callers in the wild mix --dry-run and
# --all-projects either way (matches fleet-cleanup.sh's getopt loop).
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_FLAG=1; shift ;;
    --all-projects) ALL_PROJECTS=1; shift ;;
    *)              break ;;
  esac
done
[ "${DRY_RUN:-0}" = "1" ] && DRY_FLAG=1

SUBCMD="${1:-}"
case "$SUBCMD" in
  worktrees|feedback-assets|orphan-assets|scaling-alerts|local-debt|all) ;;
  "") printf 'usage: sweep-janitor.sh [--dry-run] [--all-projects] <worktrees|feedback-assets|orphan-assets|scaling-alerts|local-debt|all>\n' >&2; exit 2 ;;
  *)  printf 'unknown subcommand: %s\n' "$SUBCMD" >&2; exit 2 ;;
esac

# --all-projects only makes sense on cross-project sweeps. Other sub-commands
# are deliberately project-scoped (e.g. scaling-alerts touches one feedback
# inbox); pretending to fan them out would silently behave wrong.
if [ "$ALL_PROJECTS" = "1" ] && [ "$SUBCMD" != "all" ] && [ "$SUBCMD" != "local-debt" ]; then
  printf '--all-projects requires `all` or `local-debt` subcommand\n' >&2; exit 2
fi

# Fan-out path: re-exec per project with ACHILLES_PROJECT pinned. One process
# per project keeps the safe_delete prefix-check honest (PROJECT_ROOT differs).
if [ "$ALL_PROJECTS" = "1" ]; then
  flags=()
  [ "$DRY_FLAG" = "1" ] && flags+=(--dry-run)
  rc=0
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    printf '== %s ==\n' "$project" >&2
    ACHILLES_PROJECT="$project" "$0" "${flags[@]}" "$SUBCMD" || rc=$?
  done < <(list_fleet_projects)
  exit "$rc"
fi

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
STATE_DIR="$PROJECT_ROOT/.runtime/state"
RUNTIME_GLOBAL=$(resolve_runtime_global)

# Running totals — feed the cleanup_completed event at the end.
archived=0
freed_bytes=0

# Safety check: every delete must fall under the project root. A bad
# resolver or an attacker-controlled symlink target would otherwise let us
# unlink arbitrary files. Callers MUST route through safe_delete.
safe_delete() {
  local target="$1" type="${2:-path}"
  case "$target" in
    "$PROJECT_ROOT"/*) ;;
    *) printf 'safe_delete: refusing to delete %s (outside %s)\n' "$target" "$PROJECT_ROOT" >&2; return 1 ;;
  esac
  local size=0
  if [ -f "$target" ]; then
    size=$(stat -f %z "$target" 2>/dev/null || stat -c %s "$target" 2>/dev/null || echo 0)
  elif [ -d "$target" ]; then
    # du output is in 1K blocks on macOS/Linux by default — convert to bytes.
    size=$(du -sk "$target" 2>/dev/null | awk '{print $1 * 1024}')
  fi
  if [ "$DRY_FLAG" = "1" ]; then
    printf 'DRY-RUN delete %s (%s bytes)\n' "$target" "${size:-0}" >&2
  else
    rm -rf "$target" 2>/dev/null || return 1
  fi
  archived=$(( archived + 1 ))
  freed_bytes=$(( freed_bytes + ${size:-0} ))
}

# Narrow allowlist twin of safe_delete for machine-global DerivedData under
# ~/.dev-studio/.runtime/derived-data/. Refuses anything outside that exact
# subdir — DerivedData is the only machine-global artifact this script deletes.
safe_delete_global() {
  local target="$1"
  case "$target" in
    "$RUNTIME_GLOBAL"/derived-data/*) ;;
    *) printf 'safe_delete_global: refusing to delete %s (outside %s/derived-data/)\n' "$target" "$RUNTIME_GLOBAL" >&2; return 1 ;;
  esac
  local size=0
  if [ -d "$target" ]; then
    size=$(du -sk "$target" 2>/dev/null | awk '{print $1 * 1024}')
  fi
  if [ "$DRY_FLAG" = "1" ]; then
    printf 'DRY-RUN delete %s (%s bytes)\n' "$target" "${size:-0}" >&2
  else
    rm -rf "$target" 2>/dev/null || return 1
  fi
  archived=$(( archived + 1 ))
  freed_bytes=$(( freed_bytes + ${size:-0} ))
}

now_s=$(date -u +%s)

sweep_worktrees() {
  local root="$PROJECT_ROOT/worktrees"
  [ -d "$root" ] || return 0
  # Snapshot the live worktree list so we skip in-use checkouts.
  local live
  live=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | awk '{print $1}' | grep "^$root" || true)
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    # Skip active reviews — presence of `.argus-running` means a reviewer is
    # actively working here. Never delete under a live reviewer's feet.
    [ -f "$d/.argus-running" ] && continue
    # Skip if git still considers this a registered worktree.
    case "$live" in
      *"$d"*) continue ;;
    esac
    local m
    m=$(mtime "$d" 2>/dev/null || echo 0)
    local age_s=$(( now_s - m ))
    # 7 days = 604800 seconds.
    [ "$age_s" -lt 604800 ] && continue
    safe_delete "$d" worktree || true
  done
}

sweep_feedback_assets() {
  local root="$PROJECT_ROOT/plans/feedback-attachments"
  [ -d "$root" ] || return 0
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    local fid
    fid=$(basename "$d")
    # Resolve the feedback record — state + age gate the delete.
    local fyaml="$PROJECT_ROOT/plans/feedback/$fid.yaml"
    [ -f "$fyaml" ] || continue
    command -v yq >/dev/null 2>&1 || continue
    local state
    state=$(yq -r '.state // ""' "$fyaml" 2>/dev/null || echo "")
    [ "$state" = "archived" ] || continue
    local m
    m=$(mtime "$d" 2>/dev/null || echo 0)
    local age_s=$(( now_s - m ))
    # 30 days = 2592000 seconds.
    [ "$age_s" -lt 2592000 ] && continue
    safe_delete "$d" feedback-attachment || true
  done
}

sweep_orphan_assets() {
  local root="$PROJECT_ROOT/plans/chanakya-inbox/assets"
  [ -d "$root" ] || return 0
  # Build a referenced-set from active + incoming + archive feedback files.
  # A file name appearing anywhere in screenshot_path:/video_path: values is
  # considered referenced regardless of the enclosing directory.
  local refs_tmp
  refs_tmp=$(mktemp 2>/dev/null) || return 0
  for src in \
      "$PROJECT_ROOT/feedback/active.md" \
      "$PROJECT_ROOT/feedback/incoming"/*.md \
      "$PROJECT_ROOT/feedback/archive"/*.md; do
    [ -f "$src" ] || continue
    grep -E '(screenshot_path|video_path):' "$src" 2>/dev/null \
      | sed -E 's|.*/||; s|[[:space:]]*$||' \
      >> "$refs_tmp"
  done
  # Walk every file under assets/, skip referenced ones, gate unreferenced
  # deletes on age (<7 days → leave; ≥7 → delete).
  find "$root" -type f 2>/dev/null | while IFS= read -r f; do
    local base
    base=$(basename "$f")
    if grep -Fxq "$base" "$refs_tmp" 2>/dev/null; then
      continue
    fi
    local m age_s
    m=$(mtime "$f" 2>/dev/null || echo 0)
    age_s=$(( now_s - m ))
    # 7 days = 604800 seconds.
    if [ "$age_s" -ge 604800 ]; then
      safe_delete "$f" orphan-asset || true
    else
      printf 'orphan-asset (newer than 7d, leaving): %s\n' "$f" >&2
    fi
  done
  rm -f "$refs_tmp" 2>/dev/null || true
}

sweep_scaling_alerts() {
  local active="$PROJECT_ROOT/feedback/active.md"
  [ -f "$active" ] || return 0
  # Row count heuristic: lines starting with `| F` (F-record table rows).
  # Keeps us resilient to section reordering.
  local rows
  rows=$(grep -cE '^\| *F[0-9]' "$active" 2>/dev/null || echo 0)
  rows=${rows:-0}
  if [ "$rows" -ge 100 ]; then
    printf '⛔ feedback/active.md has %s records — ingest refused. Run /chanakya feedback-archive.\n' "$rows"
    if [ "$DRY_FLAG" = "0" ]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      printf 'rows: %s\nset_at: %s\n' "$rows" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$STATE_DIR/feedback_ingest_blocked" 2>/dev/null || true
    fi
  elif [ "$rows" -gt 50 ]; then
    printf '⚠️ feedback/active.md has %s records; run /chanakya feedback-archive to prune.\n' "$rows"
  fi
}

# Issue #31 — process-gated cleanup that complements the time-gated sweeps
# above. Three independent passes:
#   (a) worktrees whose branch is fully merged into a protected base
#   (b) DerivedData dirs whose worktree is gone
#   (c) xcodebuild.lock whose pid file points at a dead process
sweep_local_debt() {
  # (a) merged worktrees — distinct from sweep_worktrees, which gates on
  # mtime + git-worktree-list membership. Here we delete a still-registered
  # worktree if its branch is already in main; the work is reclaimable
  # whether or not 7 days have passed.
  local root="$PROJECT_ROOT/worktrees" base wt branch
  if [ -d "$root" ]; then
    base=""
    for candidate in main master trunk develop; do
      if git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
        base="$candidate"; break
      fi
    done
    if [ -n "$base" ]; then
      for wt in "$root"/*; do
        [ -d "$wt" ] || continue
        [ -f "$wt/.argus-running" ] && continue
        branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || continue
        # Is this branch fully merged into base? `git branch --merged base`
        # lists local branches reachable from base — exact-match wins.
        if git -C "$PROJECT_ROOT" branch --merged "$base" 2>/dev/null \
            | sed 's/^[* ] *//' | grep -Fxq "$branch"; then
          # Detach the registered worktree before unlinking its dir, otherwise
          # `git worktree list` keeps a stale entry pointing at nothing.
          git -C "$PROJECT_ROOT" worktree remove --force "$wt" 2>/dev/null || true
          [ -d "$wt" ] && safe_delete "$wt" merged-worktree || true
        fi
      done
    fi
  fi

  # (b) orphan DerivedData — directory layout is
  # ~/.dev-studio/.runtime/derived-data/<worktree-slug>/. The slug matches the
  # worktree's basename (see resolve_derived_data_for in lib-paths.sh). If no
  # worktree under any project still uses that slug, the dir is reclaimable.
  local dd_root="$RUNTIME_GLOBAL/derived-data" dd slug
  if [ -d "$dd_root" ]; then
    for dd in "$dd_root"/*; do
      [ -d "$dd" ] || continue
      slug=$(basename "$dd")
      # Cross-project worktree existence check. find -path is portable; one
      # process for all projects beats a per-project loop.
      if find "$HOME/.dev-studio" -maxdepth 3 -type d -name "$slug" \
          -path '*/worktrees/*' -print -quit 2>/dev/null | grep -q .; then
        continue
      fi
      safe_delete_global "$dd" orphan-derived-data || true
    done
  fi

  # (c) dead-pid xcodebuild lock. The 45-min mtime reclaim in the skill
  # blocks new builds for up to 45 minutes after a crash; PID check is
  # immediate and correct (kill -0 returns 0 iff the process exists).
  local lock="$PROJECT_ROOT/locks/xcodebuild.lock" lock_pid
  if [ -d "$lock" ] && [ -f "$lock/pid" ]; then
    lock_pid=$(cat "$lock/pid" 2>/dev/null | tr -dc '0-9')
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      safe_delete "$lock" dead-pid-xcodebuild-lock || true
    fi
  fi
}

case "$SUBCMD" in
  worktrees)        sweep_worktrees ;;
  feedback-assets)  sweep_feedback_assets ;;
  orphan-assets)    sweep_orphan_assets ;;
  scaling-alerts)   sweep_scaling_alerts ;;
  local-debt)       sweep_local_debt ;;
  all)
    sweep_worktrees
    sweep_feedback_assets
    sweep_orphan_assets
    sweep_scaling_alerts
    sweep_local_debt
    ;;
esac

# Report via cleanup_completed. Skip emission for pure scaling-alerts runs
# since those touch nothing, but emit for every other path — downstream
# analytics consume this for cleanup-rate visibility.
if [ "$SUBCMD" != "scaling-alerts" ]; then
  # Byte → gigabyte with one decimal place. bc is standard on macOS/Linux.
  freed_gb=$(awk -v b="$freed_bytes" 'BEGIN { printf "%.2f", b / (1024*1024*1024) }')
  emit_event_keyed chanakya inbox-sweep cleanup_completed "" \
    "{\"archived\":$archived,\"freed_gb\":$freed_gb}" >/dev/null || true
fi

exit 0
