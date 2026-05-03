#!/usr/bin/env bash
# archive-legacy-surfaces.sh — #245 Stage A.4
#
# Moves the legacy debrief-shaped surfaces of a project's plans/ tree into
# plans/.legacy-archive/ (read-only) and writes an ARCHIVED.yaml marker. After
# this runs, lib-ledger's legacy_master_plan_*/legacy_inbox_*/legacy_brief_*
# helpers refuse to write — so any straggler dual-write call site fails loud
# instead of silently re-creating the legacy surface.
#
# Scope (moved):
#   plans/chanakya-tasks/                       — whole tree, no live writers
#   plans/chanakya-inbox/<task>-debrief.md      — task debriefs (Achilles)
#   plans/chanakya-inbox/build-*-debrief.md     — manual-build-check debriefs
#   plans/chanakya-inbox/tf-*-debrief.md        — TestFlight release debriefs
#   plans/chanakya-inbox/release-*-debrief.md   — release-cycle debriefs
#   plans/chanakya-inbox/processed/*-debrief.md — already-processed debriefs
#
# Preserved (live, not legacy — per #245 A.1 OOS list):
#   plans/chanakya-master.md                    — rendered projection (#273)
#   plans/chanakya-inbox/assets/                — sweep-janitor still prunes
#   plans/chanakya-inbox/*-tests.md             — historical test-case sidecars (read-only import fallback)
#   plans/chanakya-inbox/*-test-cases.md        — same shape, older naming
#   plans/chanakya-inbox/{design,product}-report-*.md
#   plans/chanakya-inbox/processed/feedback-attachments/
#   any other non-debrief-shaped .md (e.g. drafts, scratch notes)
#
# Idempotent: re-running on an already-archived project is a no-op (marker
# present + no sources to move). Future runs after a new debrief lands
# (e.g. mid-window dispatch) sweep that one file in.
#
# Usage:
#   scripts/archive-legacy-surfaces.sh [--project=<slug>] [--dry-run] [--force]
#
#   --project=<slug>  override auto-detection (cross-project / synthetic tests)
#   --dry-run         list what would move; touch nothing
#   --force           re-write the marker even if it exists (recovery)
#
# Exit codes:
#   0  success (or no-op)
#   2  fatal — cannot resolve project, missing plans/, mv failure
#   64 bad args

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project=*) PROJECT="${1#--project=}" ;;
    --dry-run)   DRY_RUN=1 ;;
    --force)     FORCE=1 ;;
    --help|-h)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           printf 'unknown arg: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

[ -z "$PROJECT" ] && PROJECT=$(resolve_project 2>/dev/null || echo "")
[ -z "$PROJECT" ] && { printf 'cannot resolve project — pass --project=<slug>\n' >&2; exit 2; }

PLANS_DIR=$(resolve_plans_dir_for "$PROJECT" 2>/dev/null || echo "")
[ -z "$PLANS_DIR" ] && { printf 'cannot resolve plans dir for project=%s\n' "$PROJECT" >&2; exit 2; }
[ -d "$PLANS_DIR" ] || { printf 'archive-legacy-surfaces: no plans dir at %s — nothing to archive\n' "$PLANS_DIR" >&2; exit 0; }

ARCHIVE_ROOT="$PLANS_DIR/.legacy-archive"
MARKER="$ARCHIVE_ROOT/ARCHIVED.yaml"

LEGACY_TASKS_DIR="$PLANS_DIR/chanakya-tasks"
INBOX_DIR="$PLANS_DIR/chanakya-inbox"

log()   { printf '%s\n' "$*" >&2; }
do_mv() {
  local src="$1" dst="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN move: %s -> %s\n' "$src" "$dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" || return 2
  mv "$src" "$dst" || return 2
}

moved_count=0

# ---- chanakya-tasks/ : move the whole subtree (no live writers post-#67/#281).
if [ -d "$LEGACY_TASKS_DIR" ]; then
  # If a previous partial run left .legacy-archive/chanakya-tasks/, merge the
  # remaining files in (no overwrite — archived copies win).
  if [ -d "$ARCHIVE_ROOT/chanakya-tasks" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      rel="${f#$LEGACY_TASKS_DIR/}"
      dst="$ARCHIVE_ROOT/chanakya-tasks/$rel"
      if [ -e "$dst" ]; then
        log "  skip (already archived): $rel"
        if [ "$DRY_RUN" = "0" ]; then rm -f "$f" || true; fi
      else
        do_mv "$f" "$dst" || { log "  FAILED: $rel"; exit 2; }
        moved_count=$((moved_count + 1))
      fi
    done < <(find "$LEGACY_TASKS_DIR" -type f 2>/dev/null)
    if [ "$DRY_RUN" = "0" ]; then
      find "$LEGACY_TASKS_DIR" -type d -empty -delete 2>/dev/null || true
      [ -d "$LEGACY_TASKS_DIR" ] && [ -z "$(ls -A "$LEGACY_TASKS_DIR" 2>/dev/null)" ] && rmdir "$LEGACY_TASKS_DIR" 2>/dev/null || true
    fi
  else
    do_mv "$LEGACY_TASKS_DIR" "$ARCHIVE_ROOT/chanakya-tasks" || { log "  FAILED to move chanakya-tasks/"; exit 2; }
    moved_count=$((moved_count + 1))
    log "  moved: chanakya-tasks/ (subtree)"
  fi
fi

# ---- chanakya-inbox/ : selective sweep — debrief-shaped files only.
# Single pass with case classification — every *-debrief.md basename is a
# debrief regardless of prefix (build-/tf-/release-/<task-id>-). The earlier
# multi-pass shape double-listed in --dry-run output because the prefix-specific
# globs and the catch-all both matched the same file in the same shell loop
# (real runs were unaffected — first mv removed the file from disk).
if [ -d "$INBOX_DIR" ]; then
  for f in "$INBOX_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      *-debrief.md)
        do_mv "$f" "$ARCHIVE_ROOT/chanakya-inbox/$base" || { log "  FAILED: chanakya-inbox/$base"; exit 2; }
        moved_count=$((moved_count + 1))
        log "  moved: chanakya-inbox/$base"
        ;;
      *) ;;  # tests, design/product reports, scratch notes — preserved
    esac
  done

  # processed/ — sweep debrief-shaped files only; preserve feedback-attachments/.
  if [ -d "$INBOX_DIR/processed" ]; then
    for f in "$INBOX_DIR"/processed/*-debrief.md; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      do_mv "$f" "$ARCHIVE_ROOT/chanakya-inbox/processed/$base" || {
        log "  FAILED: chanakya-inbox/processed/$base"; exit 2;
      }
      moved_count=$((moved_count + 1))
      log "  moved: chanakya-inbox/processed/$base"
    done
  fi
fi

# ---- Marker ---------------------------------------------------------------
write_marker() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN marker: would write %s\n' "$MARKER"
    return 0
  fi
  mkdir -p "$ARCHIVE_ROOT" || return 2
  local studio_sha=""
  studio_sha=$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || echo "")
  cat > "$MARKER" <<EOF
schema_version: {name: legacy-archive-marker, version: 1.0.0}
project: $PROJECT
archived_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
archived_by: archive-legacy-surfaces.sh
studio_sha: ${studio_sha:-unknown}
issue: 245
note: |
  Legacy debrief-shaped surfaces archived under #245 Stage A.4. The companion
  Stage A.5 retired the lib-ledger legacy_*_helpers (fail-loud stubs) and
  removed every internal call site. Migration tools (migrate-ledger.sh,
  detect-edits.sh, verify-ledger.sh) read from the archive; nothing writes
  back here. The marker itself is informational — guards in lib-ledger don't
  consult it.
EOF
}

if [ -f "$MARKER" ] && [ "$FORCE" = "0" ]; then
  log "marker exists — leaving in place ($MARKER)"
else
  write_marker || { log "FAILED to write marker"; exit 2; }
  log "wrote marker: $MARKER"
fi

# ---- Event ---------------------------------------------------------------
if [ "$DRY_RUN" = "0" ]; then
  data=$(printf '{"project":"%s","moved_count":%d,"archive_root":"%s"}' \
    "$PROJECT" "$moved_count" "$ARCHIVE_ROOT")
  ACHILLES_PROJECT="$PROJECT" append_event chanakya legacy_surfaces_archived "" "$data" 2>/dev/null || true
fi

log "archive-legacy-surfaces: project=$PROJECT moved=$moved_count dry-run=$DRY_RUN"
exit 0
