#!/usr/bin/env bash
# achilles-dispatch.sh <task-id> [worker-N|any] [-- <flags...>]
#
# Writes a task file into a worker's inbox within the current project's fleet.
# With "any" (default) picks the alive worker with the lowest current load
# (busy-flag + pending-count). Cross-project dispatch: set ACHILLES_PROJECT.
#
# Affinity features (best-effort — never fail dispatch):
#   prefers_node  — routes to the named worker if alive; spills otherwise
#   touchpoints   — warns to stderr when a dispatched task overlaps on files
#
# Examples:
#   achilles-dispatch.sh T001
#   achilles-dispatch.sh T002 worker-3
#   achilles-dispatch.sh T004 any -- --wait --force-build
#   ACHILLES_PROJECT=other-app achilles-dispatch.sh T001

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

TASK_ID="${1:?usage: achilles-dispatch.sh <task-id> [worker-N|any] [-- <flags>]}"
TARGET="${2:-any}"
shift || true
[ "${1:-}" != "" ] && shift || true
[ "${1:-}" = "--" ] && shift
FLAGS="${*:-}"

ROOT=$(resolve_inbox_root) || exit 1
HEARTBEAT_MAX=180

if ! command -v yq >/dev/null 2>&1; then
  echo "error: yq required for dispatch gating" >&2
  exit 2
fi

is_alive() {
  local d="$1"
  [ -f "$d/alive" ] || return 1
  local age=$(( $(date +%s) - $(mtime "$d/alive") ))
  [ "$age" -lt "$HEARTBEAT_MAX" ]
}

count_pending() {
  find "$1/inbox" -maxdepth 1 -name '*.task' 2>/dev/null | wc -l | tr -d ' '
}

pick_worker() {
  local best="" best_load=999
  shopt -s nullglob
  for d in "$ROOT"/worker-*/; do
    is_alive "$d" || continue
    local n
    n=$(basename "$d" | sed 's/worker-//')
    local busy=0; [ -f "$d/busy" ] && busy=1
    local pending
    pending=$(count_pending "$d")
    local load=$(( busy + pending ))
    if [ "$load" -lt "$best_load" ]; then
      best_load=$load; best="$n"
    fi
  done
  shopt -u nullglob
  [ -n "$best" ] || { echo "no alive workers under $ROOT" >&2; exit 1; }
  echo "$best"
}

# Resolve per-task YAML by legacy_task_id (e.g. T254) or UUID prefix.
# Returns path on stdout; empty if not found. Never fails dispatch.
_find_task_yaml() {
  local id="$1"
  local pr
  pr=$(resolve_project_root 2>/dev/null) || return 0
  local tasks_dir="$pr/plans/tasks"
  [ -d "$tasks_dir" ] || return 0
  local f lid uid
  for f in "$tasks_dir"/*.yaml; do
    [ -f "$f" ] || continue
    lid=$(yq -r '.legacy_task_id // ""' "$f" 2>/dev/null) || continue
    [ "$lid" = "$id" ] && { echo "$f"; return 0; }
    uid=$(yq -r '.id // ""' "$f" 2>/dev/null) || continue
    case "$uid" in "$id"*) echo "$f"; return 0 ;; esac
  done
}

_task_dispatch_unmet_predecessors() {
  local task_yaml="$1"
  local preds
  preds=$(yq -r '.predecessors[]?' "$task_yaml" 2>/dev/null) || return 0
  [ -n "$preds" ] || return 0
  local pr
  pr=$(resolve_project_root 2>/dev/null) || return 0
  local tasks_dir="$pr/plans/tasks"
  local pred pred_file pred_state pred_duplicate
  while IFS= read -r pred; do
    [ -n "$pred" ] || continue
    pred_file="$tasks_dir/$pred.yaml"
    if [ ! -f "$pred_file" ]; then
      printf '%s:missing\n' "$pred"
      continue
    fi
    pred_state=$(yq -r '.state // ""' "$pred_file" 2>/dev/null || echo "")
    pred_duplicate=$(yq -r '.duplicate_of // ""' "$pred_file" 2>/dev/null || echo "")
    case "$pred_state" in
      merged|verified|archived) continue ;;
    esac
    [ -n "$pred_duplicate" ] && continue
    printf '%s:%s\n' "$pred" "${pred_state:-unknown}"
  done <<< "$preds"
}

# Warn to stderr when active dispatched tasks share touchpoints with TASK_YAML.
_check_touchpoint_overlap() {
  local task_yaml="$1"
  command -v yq >/dev/null 2>&1 || return 0
  local my_tps
  my_tps=$(yq -r '.affinity.touchpoints[]?' "$task_yaml" 2>/dev/null) || return 0
  [ -n "$my_tps" ] || return 0
  local pr
  pr=$(resolve_project_root 2>/dev/null) || return 0
  local tasks_dir="$pr/plans/tasks"
  [ -d "$tasks_dir" ] || return 0
  local my_id
  my_id=$(yq -r '.id // ""' "$task_yaml" 2>/dev/null)
  local f state other_id other_tps other_title
  for f in "$tasks_dir"/*.yaml; do
    [ -f "$f" ] || continue
    state=$(yq -r '.state // ""' "$f" 2>/dev/null) || continue
    [ "$state" = "dispatched" ] || continue
    other_id=$(yq -r '.id // ""' "$f" 2>/dev/null) || continue
    [ "$other_id" = "$my_id" ] && continue
    other_tps=$(yq -r '.affinity.touchpoints[]?' "$f" 2>/dev/null) || continue
    [ -n "$other_tps" ] || continue
    other_title=$(yq -r '.title // "unknown"' "$f" 2>/dev/null)
    local my_tp other_tp
    while IFS= read -r my_tp; do
      [ -n "$my_tp" ] || continue
      while IFS= read -r other_tp; do
        [ -n "$other_tp" ] || continue
        case "$my_tp" in "$other_tp"*) ;;
          *) case "$other_tp" in "$my_tp"*) ;; *) continue ;; esac ;;
        esac
        printf 'warn: touchpoint overlap with dispatched task %s ("%s"): %s\n' \
          "$other_id" "$other_title" "$my_tp" >&2
      done <<< "$other_tps"
    done <<< "$my_tps"
  done
}

# --- Resolve initial worker selection ---

if [ "$TARGET" = "any" ]; then
  N=$(pick_worker)
else
  N="${TARGET#worker-}"
fi

# --- Affinity: prefers_node and touchpoint overlap (best-effort) ---

DISPATCH_REASON="round_robin"
TASK_YAML=$(_find_task_yaml "$TASK_ID") || true

if [ -n "$TASK_YAML" ]; then
  UNMET_PREDECESSORS=$(_task_dispatch_unmet_predecessors "$TASK_YAML")
  if [ -n "$UNMET_PREDECESSORS" ]; then
    printf 'dispatch blocked: %s has unresolved predecessors:\n%s\n' "$TASK_ID" "$UNMET_PREDECESSORS" >&2
    exit 2
  fi
  PREFERRED_NODE=$(yq -r '.affinity.prefers_node // ""' "$TASK_YAML" 2>/dev/null) || PREFERRED_NODE=""
  if [ -n "$PREFERRED_NODE" ] && [ "$TARGET" = "any" ]; then
    PREFERRED_N="${PREFERRED_NODE#worker-}"
    if is_alive "$ROOT/worker-$PREFERRED_N" 2>/dev/null; then
      N="$PREFERRED_N"
      DISPATCH_REASON="prefers_node"
    else
      printf 'warn: prefers_node=%s not alive — spilling to worker-%s\n' \
        "$PREFERRED_NODE" "$N" >&2
      DISPATCH_REASON="prefers_node_spill"
    fi
  fi
  _check_touchpoint_overlap "$TASK_YAML" || true
fi

DIR="$ROOT/worker-$N"
mkdir -p "$DIR/inbox"
is_alive "$DIR" || { echo "worker-$N is not alive (no recent heartbeat)" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
FILE="$DIR/inbox/${STAMP}-${TASK_ID}.task"
{
  echo "task_id=$TASK_ID"
  echo "flags=$FLAGS"
  echo "dispatched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "dispatched_from=${USER:-unknown}@${HOSTNAME:-$(hostname)}"
} > "$FILE.tmp"
mv "$FILE.tmp" "$FILE"

# Blind-spot signals (#11 / #20): best-effort, won't fail the dispatch.
emit_predispatch_signals "$TASK_ID" 2>/dev/null || true

emit_event_keyed chanakya dispatch dispatch_routed "$TASK_ID" \
  "{\"task_id\":\"$TASK_ID\",\"node_id\":\"worker-$N\",\"reason\":\"$DISPATCH_REASON\"}" \
  2>/dev/null || true

echo "dispatched $TASK_ID -> worker-$N"
echo "  $FILE"
