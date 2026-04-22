#!/usr/bin/env bash
# sweep-enumerate-debriefs.sh — Step 0 of the inbox sweep.
#
# Enumerates unprocessed debrief artifacts across both the post-2.6 YAML
# surface (plans/debriefs/*.yaml with state=emitted) and the legacy markdown
# inbox (plans/chanakya-inbox/<task>-debrief.md, build-*, tf-*, release-*),
# classifies each by kind, and prints one tab-separated triple per line:
#
#   <kind>\t<path>\t<mode>
#
#   kind ∈ {task-debrief, manual-build-check, release, direct-debrief}
#   mode ∈ {yaml, legacy}
#
# Legacy hits emit a `legacy_artifact_read` event (deduped by kind, one emit
# per sweep per kind) so the transition to the YAML canonical surface stays
# observable. Empty output is valid — exits 0 unconditionally so the caller
# can short-circuit on an empty sweep.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0

# Legacy-read dedupe: emit at most one event per kind per sweep. Short-lived,
# lives in-script only — persistent idempotency is by debrief state (YAML) or
# the processed/ move (legacy), which already no-op on re-runs.
LEGACY_EMIT_TASK=0
LEGACY_EMIT_BUILD=0
LEGACY_EMIT_RELEASE=0

emit_legacy_once() {
  local kind="$1"
  case "$kind" in
    task-debrief)
      [ "$LEGACY_EMIT_TASK" = "1" ] && return 0
      LEGACY_EMIT_TASK=1
      ;;
    manual-build-check)
      [ "$LEGACY_EMIT_BUILD" = "1" ] && return 0
      LEGACY_EMIT_BUILD=1
      ;;
    release)
      [ "$LEGACY_EMIT_RELEASE" = "1" ] && return 0
      LEGACY_EMIT_RELEASE=1
      ;;
    *) return 0 ;;
  esac
  append_event chanakya legacy_artifact_read "" \
    "{\"domain\":\"debriefs\",\"reason\":\"legacy_debrief_ingest\",\"caller\":\"sweep-enumerate-debriefs\",\"kind\":\"$kind\"}" \
    2>/dev/null || true
}

# ---- YAML surface --------------------------------------------------------
# Glob plans/debriefs/*.yaml; filter to state=emitted (missing `state` reads
# as emitted for pre-2.0.1 back-compat per inbox-sweep.md).
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
if [ -n "$DEBRIEFS_DIR" ] && [ -d "$DEBRIEFS_DIR" ] && command -v yq >/dev/null 2>&1; then
  for yaml in "$DEBRIEFS_DIR"/*.yaml; do
    [ -f "$yaml" ] || continue
    state=$(yq -r '.state // "emitted"' "$yaml" 2>/dev/null || echo emitted)
    [ "$state" = "emitted" ] || continue
    mode=$(yq -r '.mode // "task"' "$yaml" 2>/dev/null || echo task)
    task_id=$(yq -r '.task_id // ""' "$yaml" 2>/dev/null || echo "")
    case "$mode" in
      task)
        if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
          printf 'direct-debrief\t%s\tyaml\n' "$yaml"
        else
          printf 'task-debrief\t%s\tyaml\n' "$yaml"
        fi
        ;;
      manual-build-check)
        printf 'manual-build-check\t%s\tyaml\n' "$yaml"
        ;;
      release)
        printf 'release\t%s\tyaml\n' "$yaml"
        ;;
      direct-debrief)
        # Pre-2.0.1 naming; treat as direct-debrief regardless of task_id.
        printf 'direct-debrief\t%s\tyaml\n' "$yaml"
        ;;
      *)
        # Unknown mode — surface as task-debrief so it's at least visible.
        printf 'task-debrief\t%s\tyaml\n' "$yaml"
        ;;
    esac
  done
fi

# ---- Legacy surface ------------------------------------------------------
# Walk plans/chanakya-inbox/ — ignore processed/ and *-tests.md.
PLANS_DIR=$(resolve_plans_dir_for "$PROJECT" 2>/dev/null || echo "")
INBOX_DIR="$PLANS_DIR/chanakya-inbox"
if [ -n "$PLANS_DIR" ] && [ -d "$INBOX_DIR" ]; then
  for f in "$INBOX_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    # Skip test-plan siblings — those are read-only references, not debriefs.
    case "$base" in
      *-tests.md) continue ;;
    esac
    case "$base" in
      build-*-debrief.md)
        # Legacy manual-build-check debriefs carry `Type: manual-build-check`
        # in the first few header lines.
        if head -n 20 "$f" 2>/dev/null | grep -qE '^[A-Za-z ]*Type: *manual-build-check'; then
          emit_legacy_once manual-build-check
          printf 'manual-build-check\t%s\tlegacy\n' "$f"
        fi
        ;;
      tf-*-debrief.md)
        emit_legacy_once release
        printf 'release\t%s\tlegacy\n' "$f"
        ;;
      release-*-debrief.md)
        emit_legacy_once release
        printf 'release\t%s\tlegacy\n' "$f"
        ;;
      *-debrief.md)
        # Regular task debriefs — `<task-id>-debrief.md`.
        emit_legacy_once task-debrief
        printf 'task-debrief\t%s\tlegacy\n' "$f"
        ;;
    esac
  done
fi

exit 0
