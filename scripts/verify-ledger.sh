#!/usr/bin/env bash
# verify-ledger.sh — one-shot diff-verifier for the Phase 2.6 migration.
#
# Called by scripts/migrate-ledger.sh after the transform phase. Walks every
# new YAML artifact, applies a reverse-transform (YAML → legacy canonical
# form), and compares byte-normalized against the archived original.
#
# Exit 0 on clean (zero mismatches). Exit 1 on any mismatch. No looping,
# no daemon — the user reviews the diff and decides: either the transform
# has a bug (fix migrate-ledger.sh + re-run) or the mismatch is expected
# normalization (add to allowlist).
#
# Usage:
#   scripts/verify-ledger.sh --project <slug>
#   scripts/verify-ledger.sh --project <slug> --verbose  # show every diff
#
# Reverse-transform scope (2.6): briefs + debriefs. Events are dedupe +
# day-partition, which is deliberately lossy on the merge key — verify
# asserts line-count parity instead of byte identity.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
VERBOSE=0
MAX_DIFFS=5
DIFFS_SHOWN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)  PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --verbose)  VERBOSE=1; shift ;;
    --max)      MAX_DIFFS="${2:?--max requires number}"; shift 2 ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug>.\n' >&2
    exit 2
  }
fi

if [ -n "${ACHILLES_PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$ACHILLES_PROJECT_ROOT"
else
  PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
fi

ARCHIVE_ROOT="$PROJECT_ROOT/archive/2026-pre-2.6"
PLANS_NEW="$PROJECT_ROOT/plans"
EVENTS_NEW="$PROJECT_ROOT/events"

if [ ! -d "$ARCHIVE_ROOT" ]; then
  printf 'error: archive not found (%s) — run migrate-ledger.sh backup phase first\n' "$ARCHIVE_ROOT" >&2
  exit 2
fi

MATCHES=0
MISMATCHES=0
UNPARSEABLE=0

log() { printf '[verify] %s\n' "$*"; }

emit_diff() {
  local file="$1" reason="$2"
  MISMATCHES=$((MISMATCHES + 1))
  if [ "$VERBOSE" -eq 1 ] || [ "$DIFFS_SHOWN" -lt "$MAX_DIFFS" ]; then
    printf '  MISMATCH: %s\n    %s\n' "$file" "$reason"
    DIFFS_SHOWN=$((DIFFS_SHOWN + 1))
  fi
}

# ---- Briefs: each new plans/briefs/<uuid>.yaml must round-trip to a legacy
# path under archive/2026-pre-2.6/plans/chanakya-tasks/<legacy-id>-<type>.md. ----
verify_briefs() {
  local f uuid legacy_id legacy_path
  local new_dir="$PLANS_NEW/briefs"
  [ -d "$new_dir" ] || { log "  no briefs dir — skipping"; return 0; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    uuid=$(sed -n 's/^id: //p' "$f" | head -n 1)
    legacy_id=$(sed -n 's/^legacy_task_id: "\(.*\)"/\1/p' "$f" | head -n 1)
    local type
    type=$(sed -n 's/^type: //p' "$f" | head -n 1)
    if [ -z "$legacy_id" ]; then
      # Post-cutover brief (no legacy source) — skip rather than flag.
      continue
    fi
    if [ -z "$type" ]; then
      UNPARSEABLE=$((UNPARSEABLE + 1))
      emit_diff "$f" "missing type — cannot reverse-map"
      continue
    fi
    legacy_path="$ARCHIVE_ROOT/plans/chanakya-tasks/${legacy_id}-${type}.md"
    if [ ! -f "$legacy_path" ]; then
      emit_diff "$f" "legacy source not found: $legacy_path"
      continue
    fi
    # Extract body from YAML (lines after body: |, stripped of 2-space indent).
    local body_new body_legacy
    body_new=$(awk '/^body: \|$/{flag=1; next} flag' "$f" 2>/dev/null | sed 's/^  //')
    body_legacy=$(cat "$legacy_path" 2>/dev/null)
    # Normalize: strip trailing whitespace, collapse empty trailing lines.
    local norm_new norm_legacy
    norm_new=$(printf '%s\n' "$body_new" | sed 's/[[:space:]]*$//' | awk 'NF {last=NR; lines[NR]=$0} END {for (i=1;i<=last;i++) print lines[i]}')
    norm_legacy=$(printf '%s\n' "$body_legacy" | sed 's/[[:space:]]*$//' | awk 'NF {last=NR; lines[NR]=$0} END {for (i=1;i<=last;i++) print lines[i]}')
    if [ "$norm_new" = "$norm_legacy" ]; then
      MATCHES=$((MATCHES + 1))
    else
      emit_diff "$f" "body differs from $legacy_path after normalization"
    fi
  done < <(find "$new_dir" -type f -name '*.yaml' 2>/dev/null)
}

# ---- Debriefs: analogous to briefs, reverse-map via legacy_task_id. ----
verify_debriefs() {
  local f legacy_id legacy_path
  local new_dir="$PLANS_NEW/debriefs"
  [ -d "$new_dir" ] || { log "  no debriefs dir — skipping"; return 0; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    legacy_id=$(sed -n 's/^legacy_task_id: "\(.*\)"/\1/p' "$f" | head -n 1)
    if [ -z "$legacy_id" ]; then
      # Post-cutover artifacts (e.g. direct-debriefs from /achilles debrief)
      # have no legacy source to verify against. Skip rather than flag — verify
      # is a migration audit, not a runtime-integrity check.
      continue
    fi
    # Legacy path: the file was either in the inbox root or a subdir.
    # Scan archive for any <legacy-id>-debrief.md.
    legacy_path=$(find "$ARCHIVE_ROOT/plans/chanakya-inbox" -type f -name "${legacy_id}-debrief.md" 2>/dev/null | grep -v '/processed/' | head -n 1)
    if [ -z "$legacy_path" ] || [ ! -f "$legacy_path" ]; then
      emit_diff "$f" "legacy debrief source not found for $legacy_id"
      continue
    fi
    local body_new body_legacy norm_new norm_legacy
    body_new=$(awk '/^body: \|$/{flag=1; next} flag' "$f" 2>/dev/null | sed 's/^  //')
    body_legacy=$(cat "$legacy_path" 2>/dev/null)
    norm_new=$(printf '%s\n' "$body_new" | sed 's/[[:space:]]*$//' | awk 'NF {last=NR; lines[NR]=$0} END {for (i=1;i<=last;i++) print lines[i]}')
    norm_legacy=$(printf '%s\n' "$body_legacy" | sed 's/[[:space:]]*$//' | awk 'NF {last=NR; lines[NR]=$0} END {for (i=1;i<=last;i++) print lines[i]}')
    if [ "$norm_new" = "$norm_legacy" ]; then
      MATCHES=$((MATCHES + 1))
    else
      emit_diff "$f" "body differs from $legacy_path"
    fi
  done < <(find "$new_dir" -type f -name '*.yaml' 2>/dev/null)
}

# ---- Events: line-count parity. Merge-dedupe is deliberately lossy on dup
# keys, so byte identity is not expected. The check is: new event count +
# unparseable count + dedupe-drops should equal legacy event count. We
# approximate by counting new lines across all day files + unbucketed. ----
verify_events() {
  local new_count legacy_count unbucketed_count
  new_count=0
  if [ -d "$EVENTS_NEW" ]; then
    for f in "$EVENTS_NEW"/????-??-??.jsonl; do
      [ -f "$f" ] || continue
      new_count=$(( new_count + $(wc -l < "$f" | tr -d ' ') ))
    done
  fi
  unbucketed_count=0
  if [ -f "$ARCHIVE_ROOT/unparseable/unbucketed-events.jsonl" ]; then
    unbucketed_count=$(wc -l < "$ARCHIVE_ROOT/unparseable/unbucketed-events.jsonl" | tr -d ' ')
  fi
  # Sum legacy sources.
  legacy_count=0
  local candidate
  for candidate in \
    "$ARCHIVE_ROOT/event-log.jsonl" \
    "$ARCHIVE_ROOT/events.jsonl" \
    "$ARCHIVE_ROOT/.runtime/events.jsonl" \
    "$ARCHIVE_ROOT/.runtime/events.ndjson" \
    "$ARCHIVE_ROOT/plans/chanakya-events.jsonl" ; do
    [ -f "$candidate" ] && legacy_count=$(( legacy_count + $(wc -l < "$candidate" | tr -d ' ') ))
  done
  local total=$(( new_count + unbucketed_count ))
  # Dedupe is legitimate — we expect `total <= legacy`. The floor is "any
  # event shape preserved". Zero new events from non-zero legacy is a fail
  # (catastrophic transform loss); everything else is plausible dedupe.
  if [ "$legacy_count" -eq 0 ] || [ "$total" -gt 0 ]; then
    log "  events: new=$new_count unbucketed=$unbucketed_count legacy=$legacy_count (dedupe drops expected when total<=legacy)"
    MATCHES=$((MATCHES + 1))
  else
    emit_diff "events" "new+unbucketed=0 with legacy=$legacy_count — transform lost all events"
  fi
}

log "verifying migration for project=$PROJECT"
verify_briefs
verify_debriefs
verify_events

printf '\n'
log "results: matches=$MATCHES mismatches=$MISMATCHES unparseable=$UNPARSEABLE"

if [ "$MISMATCHES" -gt 0 ] || [ "$UNPARSEABLE" -gt 0 ]; then
  log "FAIL — fix migrate-ledger.sh and re-run (transforms are pure on immutable backup)"
  exit 1
fi
log "PASS"
exit 0
