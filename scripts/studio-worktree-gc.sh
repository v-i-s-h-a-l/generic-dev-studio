#!/usr/bin/env bash
# studio-worktree-gc.sh — garbage-collect stale studio worktrees.
#
# Layer 2 + 3 of the worktree cleanup contract documented in
# _shared/contracts/worktree-marker.md. Layer 1 (owning command removes its
# own worktree on finalize) is the responsibility of the command, not the gc.
#
# Default behavior is report-only: walks every project's worktrees dir under
# the studio root (resolved via lib-paths), reads the per-worktree marker,
# decides which entries are reapable, and emits a JSON report on stdout. With
# `--reap-stale` it also performs the reap; with `--budget-check` it adds a
# disk-budget alarm record.
#
# Usage:
#   scripts/studio-worktree-gc.sh [--project <slug>] [--ttl-days N]
#                                 [--active-ids <csv>] [--keep <csv>]
#                                 [--reap-stale] [--budget-check]
#                                 [--dry-run] [--quiet]
#
# Exit codes:
#   0  report emitted; reap (if requested) succeeded
#   1  unexpected internal error
#   2  invalid usage / arg parse failure
#   3  reap requested but at least one entry failed to remove

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-worktree-marker.sh
. "$SCRIPT_DIR/lib-worktree-marker.sh"

PROJECT_FILTER=""
TTL_DAYS="${STUDIO_WORKTREE_GC_TTL_DAYS:-7}"
ACTIVE_IDS_CSV=""
KEEP_CSV="${STUDIO_KEEP_WORKTREE:-}"
DO_REAP=0
DO_BUDGET=0
DRY_RUN=0
QUIET=0

DISK_BUDGET_BYTES="${STUDIO_WORKTREE_DISK_BUDGET_BYTES:-$((5 * 1024 * 1024 * 1024))}"
COUNT_BUDGET="${STUDIO_WORKTREE_COUNT_BUDGET:-10}"

usage() {
  sed -n '2,25p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)     PROJECT_FILTER="${2:?--project requires a slug}"; shift 2 ;;
    --ttl-days)    TTL_DAYS="${2:?--ttl-days requires N}"; shift 2 ;;
    --active-ids)  ACTIVE_IDS_CSV="${2:-}"; shift 2 ;;
    --keep)        KEEP_CSV="${2:-}"; shift 2 ;;
    --reap-stale)  DO_REAP=1; shift ;;
    --budget-check) DO_BUDGET=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'studio-worktree-gc.sh: unknown flag %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TTL_DAYS" in
  ''|*[!0-9]*) printf 'studio-worktree-gc.sh: --ttl-days must be a non-negative integer (got %s)\n' "$TTL_DAYS" >&2; exit 2 ;;
esac
TTL_SECONDS=$((TTL_DAYS * 86400))

log() {
  [ "$QUIET" = "1" ] && return 0
  printf '%s\n' "$*" >&2
}

# Disk usage for a directory, bytes. macOS `du -k` is portable; GNU `du -B1`
# is more precise. Use POSIX `-sk` and multiply.
_du_bytes() {
  local path="$1"
  [ -d "$path" ] || { printf '0\n'; return 0; }
  local kib
  kib=$(du -sk "$path" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$kib" ] || kib=0
  printf '%d\n' "$((kib * 1024))"
}

# Determine the main checkout for a project's worktrees dir. This is used to
# run `git worktree remove` from the right repo. When the worktrees dir holds
# entries that point at a primary repo elsewhere, we read the worktree's own
# git pointer file. Returns 0 + path on stdout, 1 silently otherwise.
_resolve_repo_for_worktree() {
  local wt="$1"
  local gitfile="$wt/.git"
  [ -f "$gitfile" ] || return 1
  # `.git` file in a worktree contains `gitdir: /abs/path/.git/worktrees/<id>`.
  local raw
  raw=$(awk -F': *' '/^gitdir:/ {print $2; exit}' "$gitfile" 2>/dev/null)
  [ -n "$raw" ] || return 1
  # Strip /.git/worktrees/<id> tail. `git rev-parse --git-common-dir` is the
  # robust route but requires being inside the worktree.
  local repo
  repo=$(cd "$wt" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$repo" in
    /*) ;;
    *) repo="$wt/$repo" ;;
  esac
  # repo is now <main>/.git — strip the trailing /.git.
  printf '%s\n' "${repo%/.git}"
}

_in_csv() {
  local needle="$1" csv="$2"
  [ -n "$csv" ] || return 1
  case ",$csv," in
    *,"$needle",*) return 0 ;;
    *) return 1 ;;
  esac
}

declare -a REPORT_ENTRIES=()
declare -a REAP_FAILURES=()

TOTAL_BYTES=0
TOTAL_COUNT=0
REAPED_COUNT=0
REAPABLE_COUNT=0

REPORT_TMP=$(mktemp -t studio-wt-gc.XXXXXX)
trap 'rm -f "$REPORT_TMP"' EXIT

_emit_entry() {
  # Pre-escape for JSON. Worktree dir, slug, project, kind, last_touched,
  # status, age_seconds.
  local wt="$1" slug="$2" project="$3" kind="$4" last_touched="$5"
  local status="$6" age="$7" bytes="$8" reason="$9"
  esc() {
    local s="${1-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
  }
  printf '{"worktree":"%s","slug":"%s","project":"%s","kind":"%s","last_touched":"%s","age_seconds":%d,"size_bytes":%d,"status":"%s","reason":"%s"}\n' \
    "$(esc "$wt")" "$(esc "$slug")" "$(esc "$project")" "$(esc "$kind")" \
    "$(esc "$last_touched")" "$age" "$bytes" "$(esc "$status")" "$(esc "$reason")"
}

# Walk the project worktrees roots.
shopt -s nullglob

# Resolve the studio-home root via the resolver layer (lib-paths) so this
# script never hand-rolls durable-state formulas — see CLAUDE.md
# §"Where workflow rules live" / lint-runtime-paths.
STUDIO_HOME_ROOT=$(dirname "$(resolve_project_root_for _lint_safe_placeholder_)")

declare -a PROJECT_ROOTS=()
if [ -n "$PROJECT_FILTER" ]; then
  PROJECT_ROOTS+=("$(resolve_project_root_for "$PROJECT_FILTER")")
else
  for d in "$STUDIO_HOME_ROOT"/*/ ; do
    PROJECT_ROOTS+=("${d%/}")
  done
fi

NOW_EPOCH=$(date -u +%s)

for proot in "${PROJECT_ROOTS[@]:-}"; do
  [ -d "$proot" ] || continue
  proj=$(basename "$proot")
  # Skip the runtime-global sentinel directory and similar non-project siblings.
  case "$proj" in
    .runtime|.|..) continue ;;
  esac
  wtroot="$proot/worktrees"
  [ -d "$wtroot" ] || continue
  for wt in "$wtroot"/*/ ; do
    wt="${wt%/}"
    [ -d "$wt" ] || continue
    slug=$(basename "$wt")
    marker="$wt/.studio-worktree.json"
    bytes=$(_du_bytes "$wt")
    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    if [ ! -f "$marker" ]; then
      _emit_entry "$wt" "$slug" "$proj" "unknown" "" "skipped" "0" "$bytes" "no_marker" \
        >> "$REPORT_TMP"
      REPORT_ENTRIES+=("no_marker:$wt")
      continue
    fi

    kind=$(_worktree_marker_field "$marker" kind)
    last_touched=$(_worktree_marker_field "$marker" last_touched)
    chain_id=$(_worktree_marker_field "$marker" chain_id)
    session_id=$(_worktree_marker_field "$marker" session_id)
    task_id=$(_worktree_marker_field "$marker" task_id)

    if [ -z "$last_touched" ]; then
      _emit_entry "$wt" "$slug" "$proj" "$kind" "" "skipped" "0" "$bytes" "marker_invalid" \
        >> "$REPORT_TMP"
      REPORT_ENTRIES+=("marker_invalid:$wt")
      continue
    fi

    if ! epoch=$(_worktree_marker_iso_to_epoch "$last_touched"); then
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "skipped" "0" "$bytes" "marker_unparseable" \
        >> "$REPORT_TMP"
      REPORT_ENTRIES+=("marker_unparseable:$wt")
      continue
    fi
    age=$((NOW_EPOCH - epoch))

    if _in_csv "$slug" "$KEEP_CSV"; then
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "kept" "$age" "$bytes" "STUDIO_KEEP_WORKTREE" \
        >> "$REPORT_TMP"
      continue
    fi

    active=0
    for id in "$chain_id" "$session_id" "$task_id"; do
      [ -n "$id" ] || continue
      if _in_csv "$id" "$ACTIVE_IDS_CSV"; then active=1; break; fi
    done
    if [ "$active" = "1" ]; then
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "active" "$age" "$bytes" "active_id_match" \
        >> "$REPORT_TMP"
      continue
    fi

    if [ "$age" -le "$TTL_SECONDS" ]; then
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "fresh" "$age" "$bytes" "within_ttl" \
        >> "$REPORT_TMP"
      continue
    fi

    REAPABLE_COUNT=$((REAPABLE_COUNT + 1))
    if [ "$DO_REAP" = "1" ] && [ "$DRY_RUN" != "1" ]; then
      repo=$(_resolve_repo_for_worktree "$wt" || true)
      if [ -n "$repo" ] && [ -d "$repo/.git" ]; then
        if ! git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; then
          log "warning: git worktree remove --force $wt failed; attempting filesystem rm"
        fi
      fi
      if [ -d "$wt" ]; then
        if ! rm -rf "$wt" 2>/dev/null; then
          REAP_FAILURES+=("$wt")
          _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "reap_failed" "$age" "$bytes" "rm_failed" \
            >> "$REPORT_TMP"
          continue
        fi
      fi
      REAPED_COUNT=$((REAPED_COUNT + 1))
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "reaped" "$age" "$bytes" "stale_ttl_exceeded" \
        >> "$REPORT_TMP"
    else
      action="reapable"
      [ "$DRY_RUN" = "1" ] && [ "$DO_REAP" = "1" ] && action="dry_run_reapable"
      _emit_entry "$wt" "$slug" "$proj" "$kind" "$last_touched" "$action" "$age" "$bytes" "stale_ttl_exceeded" \
        >> "$REPORT_TMP"
    fi
  done
done

# Compose summary JSON. Use jq if available, else hand-roll. The entries
# array is the only place we accumulate variable payload, and entries were
# already emitted as valid JSON objects per line into REPORT_TMP.
ENTRIES_BLOB=""
if [ -s "$REPORT_TMP" ]; then
  ENTRIES_BLOB=$(awk 'NR>1{printf ","} {printf "%s", $0}' "$REPORT_TMP")
fi

BUDGET_STATUS="ok"
BUDGET_REASON=""
if [ "$DO_BUDGET" = "1" ]; then
  if [ "$TOTAL_BYTES" -gt "$DISK_BUDGET_BYTES" ]; then
    BUDGET_STATUS="alarm"
    BUDGET_REASON="disk_budget_exceeded"
  elif [ "$TOTAL_COUNT" -gt "$COUNT_BUDGET" ]; then
    BUDGET_STATUS="alarm"
    BUDGET_REASON="count_budget_exceeded"
  fi
fi

printf '{"schema_version":1,"kind":"worktree-gc-report","generated_at":"%s","ttl_days":%d,"do_reap":%s,"dry_run":%s,"totals":{"worktrees":%d,"bytes":%d,"reapable":%d,"reaped":%d},"budget":{"status":"%s","reason":"%s","disk_bytes":%d,"disk_budget_bytes":%d,"count":%d,"count_budget":%d},"entries":[%s]}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$TTL_DAYS" \
  "$( [ "$DO_REAP" = "1" ] && printf true || printf false )" \
  "$( [ "$DRY_RUN" = "1" ] && printf true || printf false )" \
  "$TOTAL_COUNT" "$TOTAL_BYTES" "$REAPABLE_COUNT" "$REAPED_COUNT" \
  "$BUDGET_STATUS" "$BUDGET_REASON" "$TOTAL_BYTES" "$DISK_BUDGET_BYTES" "$TOTAL_COUNT" "$COUNT_BUDGET" \
  "$ENTRIES_BLOB"

if [ "$BUDGET_STATUS" = "alarm" ]; then
  log "warning: worktree budget alarm (${BUDGET_REASON}). Run: manager-cleanup.sh --worktrees"
fi

if [ "${#REAP_FAILURES[@]}" -gt 0 ]; then
  log "warning: ${#REAP_FAILURES[@]} worktree(s) failed to reap"
  exit 3
fi

exit 0
