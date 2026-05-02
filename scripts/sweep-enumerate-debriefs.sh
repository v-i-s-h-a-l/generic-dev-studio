#!/usr/bin/env bash
# sweep-enumerate-debriefs.sh — Step 0 of the inbox sweep.
#
# Enumerates unprocessed debrief artifacts under plans/debriefs/*.yaml with
# state=emitted. Classifies each by ingest subcommand and prints one
# tab-separated triple per ingestable line on stdout:
#
#   <subcommand>\t<path>\tyaml
#
#   subcommand ∈ {debrief, build-check, release}
#
# (The trailing `yaml` column is retained for caller back-compat. Debrief
# modes such as task vs direct-debrief stay in the YAML; the ingest command is
# always the canonical sweep-ingest.sh subcommand.)
#
# Non-ingestable blind spots are diagnostics, not queue items. They print to
# stderr so existing stdout consumers keep parsing only ingestable rows:
#
#   legacy-debrief\t<path>\tmode=legacy remediation=archive-or-migrate-to-plans-debriefs-yaml
#   misrouted-debrief\t<path>\tlocation=chanakya-inbox remediation=move-to-plans-debriefs-yaml
#   apollo-deferred\t<path>\tstale_blocker=false
#   stale-deferred\t<path>\tstale_blocker=true blocker=<id> blocker_state=<state>
#
# Empty output is valid — exits 0 unconditionally so the caller can
# short-circuit on an empty sweep.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-sweep-timing.sh
. "$SCRIPT_DIR/lib-sweep-timing.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
PLANS_DIR=$(resolve_plans_dir_for "$PROJECT")
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
sweep_timing_start

yaml_count=0
legacy_md_count=0
misrouted_count=0
stale_deferred_count=0
active_deferred_count=0

diagnostic() {
  printf '%s\n' "$*" >&2
}

task_state_for_blocker() {
  local blocker="$1" f state legacy id
  [ -n "$blocker" ] || return 1
  [ -d "$TASKS_DIR" ] || return 1
  for f in "$TASKS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    if command -v yq >/dev/null 2>&1; then
      yaml_parse_check "$f" sweep-enumerate-task >/dev/null 2>&1 || continue
      legacy=$(yq -r '.legacy_task_id // ""' "$f" 2>/dev/null || echo "")
      id=$(yq -r '.id // ""' "$f" 2>/dev/null || echo "")
      if [ "$legacy" = "$blocker" ] || [ "$id" = "$blocker" ]; then
        state=$(yq -r '.state // ""' "$f" 2>/dev/null || echo "")
        [ "$state" = "null" ] && state=""
        printf '%s\n' "$state"
        return 0
      fi
    fi
  done
  return 1
}

is_closed_blocker_state() {
  case "$1" in
    merged|done|verified|archived|cancelled|released) return 0 ;;
    *) return 1 ;;
  esac
}

# Glob plans/debriefs/*.yaml; filter to state=emitted (missing `state` reads
# as emitted for pre-2.0.1 back-compat per inbox-sweep.md).
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
if [ -n "$DEBRIEFS_DIR" ] && [ -d "$DEBRIEFS_DIR" ]; then
  for md in "$DEBRIEFS_DIR"/*.md; do
    [ -f "$md" ] || continue
    diagnostic "$(printf 'legacy-debrief\t%s\tmode=legacy remediation=archive-or-migrate-to-plans-debriefs-yaml' "$md")"
    legacy_md_count=$((legacy_md_count + 1))
  done
fi

if [ -n "$DEBRIEFS_DIR" ] && [ -d "$DEBRIEFS_DIR" ] && command -v yq >/dev/null 2>&1; then
  for yaml in "$DEBRIEFS_DIR"/*.yaml; do
    [ -f "$yaml" ] || continue
    # Parseability gate — malformed YAML used to silently default through
    # `.state // "emitted"` and poison the sweep queue. Skip+signal instead.
    yaml_parse_check "$yaml" sweep-enumerate || continue
    state=$(yq -r '.state // "emitted"' "$yaml" 2>/dev/null || echo emitted)
    [ "$state" = "emitted" ] || continue
    mode=$(yq -r '.mode // "task"' "$yaml" 2>/dev/null || echo task)
    task_id=$(yq -r '.task_id // ""' "$yaml" 2>/dev/null || echo "")
    case "$mode" in
      task)
        if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
          printf 'debrief\t%s\tyaml\n' "$yaml"
          yaml_count=$((yaml_count + 1))
        else
          printf 'debrief\t%s\tyaml\n' "$yaml"
          yaml_count=$((yaml_count + 1))
        fi
        ;;
      manual-build-check)
        printf 'build-check\t%s\tyaml\n' "$yaml"
        yaml_count=$((yaml_count + 1))
        ;;
      release)
        printf 'release\t%s\tyaml\n' "$yaml"
        yaml_count=$((yaml_count + 1))
        ;;
      direct-debrief)
        # Pre-2.0.1 naming; treat as direct-debrief regardless of task_id.
        printf 'debrief\t%s\tyaml\n' "$yaml"
        yaml_count=$((yaml_count + 1))
        ;;
      *)
        # Unknown mode — surface as a normal debrief so it's at least visible.
        printf 'debrief\t%s\tyaml\n' "$yaml"
        yaml_count=$((yaml_count + 1))
        ;;
    esac
  done
fi

CHANAKYA_INBOX="$PLANS_DIR/chanakya-inbox"
if [ -d "$CHANAKYA_INBOX" ]; then
  for f in "$CHANAKYA_INBOX"/*-debrief.yaml "$CHANAKYA_INBOX"/*-debrief.md; do
    [ -f "$f" ] || continue
    diagnostic "$(printf 'misrouted-debrief\t%s\tlocation=chanakya-inbox remediation=move-to-plans-debriefs-yaml' "$f")"
    misrouted_count=$((misrouted_count + 1))
  done
fi

APOLLO_DEFERRED="$PROJECT_ROOT/apollo/deferred"
if [ -d "$APOLLO_DEFERRED" ] && command -v yq >/dev/null 2>&1; then
  for yaml in "$APOLLO_DEFERRED"/*.yaml; do
    [ -f "$yaml" ] || continue
    yaml_parse_check "$yaml" sweep-enumerate-apollo >/dev/null 2>&1 || continue
    deferred_state=$(yq -r '.state // ""' "$yaml" 2>/dev/null || echo "")
    [ "$deferred_state" = "null" ] && deferred_state=""
    case "$deferred_state" in
      archived|done|completed) continue ;;
    esac
    blocker=$(yq -r '.blocker // .blocked_by // ""' "$yaml" 2>/dev/null || echo "")
    [ "$blocker" = "null" ] && blocker=""
    blocker_state=""
    [ -n "$blocker" ] && blocker_state=$(task_state_for_blocker "$blocker" 2>/dev/null || echo "")
    if [ -n "$blocker" ] && is_closed_blocker_state "$blocker_state"; then
      diagnostic "$(printf 'stale-deferred\t%s\tstale_blocker=true blocker=%s blocker_state=%s' \
        "$yaml" "$blocker" "$blocker_state")"
      stale_deferred_count=$((stale_deferred_count + 1))
    else
      if [ -n "$blocker" ]; then
        diagnostic "$(printf 'apollo-deferred\t%s\tstale_blocker=false blocker=%s' "$yaml" "$blocker")"
      else
        diagnostic "$(printf 'apollo-deferred\t%s\tstale_blocker=false' "$yaml")"
      fi
      active_deferred_count=$((active_deferred_count + 1))
    fi
  done
fi

diagnostic_count=$((legacy_md_count + misrouted_count + stale_deferred_count + active_deferred_count))
if [ "$diagnostic_count" -gt 0 ]; then
  total=$((yaml_count + diagnostic_count))
  diagnostic "$(printf 'sweep diagnostics: %s items (%s yaml, %s legacy-md, %s misrouted, %s stale-deferred) [%s active-deferred]' \
    "$total" "$yaml_count" "$legacy_md_count" "$misrouted_count" "$stale_deferred_count" "$active_deferred_count")"
fi

sweep_timing_emit enumerate completed "$yaml_count"
exit 0
