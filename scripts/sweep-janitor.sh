#!/usr/bin/env bash
# sweep-janitor.sh [--dry-run] <subcommand>
#
# Step 0D — stale-artifact sweep. Four independent subcommands:
#
#   worktrees        Prune worktree dirs older than 7 days with no
#                    active-review marker + no live `git worktree` entry.
#   feedback-assets  Prune per-feedback attachment dirs whose parent record
#                    is `state: archived` and older than 30 days.
#   orphan-assets    Prune assets under chanakya-inbox/assets/ not referenced
#                    by any feedback record; 7d mtime grace.
#   scaling-alerts   Line-count feedback/active.md; warn @ 50, block @ 100
#                    (sets feedback_ingest_blocked flag).
#   all              Run all four in order.
#
# DRY_RUN=1 (env) or --dry-run flag reports targets without deleting. Every
# unlink is prefix-checked against the project root so a misconfigured
# resolver can't walk off the reservation.
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
if [ "${1:-}" = "--dry-run" ]; then
  DRY_FLAG=1
  shift
fi
[ "${DRY_RUN:-0}" = "1" ] && DRY_FLAG=1

SUBCMD="${1:-}"
case "$SUBCMD" in
  worktrees|feedback-assets|orphan-assets|scaling-alerts|all) ;;
  "") printf 'usage: sweep-janitor.sh [--dry-run] <worktrees|feedback-assets|orphan-assets|scaling-alerts|all>\n' >&2; exit 2 ;;
  *)  printf 'unknown subcommand: %s\n' "$SUBCMD" >&2; exit 2 ;;
esac

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
STATE_DIR="$PROJECT_ROOT/.runtime/state"

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

case "$SUBCMD" in
  worktrees)        sweep_worktrees ;;
  feedback-assets)  sweep_feedback_assets ;;
  orphan-assets)    sweep_orphan_assets ;;
  scaling-alerts)   sweep_scaling_alerts ;;
  all)
    sweep_worktrees
    sweep_feedback_assets
    sweep_orphan_assets
    sweep_scaling_alerts
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
