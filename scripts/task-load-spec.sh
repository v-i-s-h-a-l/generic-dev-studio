#!/usr/bin/env bash
# task-load-spec.sh — Step 1 of the Achilles task mode.
#
# Resolves a brief for <task-id>, picking the post-2.6 YAML artifact when the
# plans/briefs ledger is populated and falling back to legacy
# plans/chanakya-tasks/<task-id>-*.md otherwise. Empty task-id → direct mode
# (no brief). Emits one `legacy_artifact_read` per fallback so the transition
# is observable.
#
# Output is eval-able (key=value per line), same contract as argus-diff-extract.sh:
#   TASK_MODE=brief|direct
#   BRIEF_PATH=<path>          (empty on direct mode)
#   BRIEF_UUID=<uuid>          (empty on legacy fallback and on direct mode)
#   SIZE=<xs|s|m|l>            (inferred `m` if legacy brief lacks a size marker)
#   TYPE=<feature|bugfix|...>  (feature is the safe default when legacy brief
#                               omits an explicit Type: line)
#   ACCEPTANCE_JSON='<json-array>'
#
# Usage:
#   eval "$(scripts/task-load-spec.sh <task-id-or-empty>)"
#
# Exit codes:
#   0  spec resolved (or direct mode)
#   2  brief requested but nothing found on either surface
#   5  task is in a terminal state (#263) — refusing re-dispatch. Override
#      with ACHILLES_REOPEN=1 (writes a follow-up debrief) or run
#      `/chanakya reopen <task-id>` for a formal state-machine reopen.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:-}"

# Direct mode short-circuit — no brief, no resolution.
if [ -z "$TASK_ID" ]; then
  printf 'TASK_MODE=direct\n'
  printf 'BRIEF_PATH=\n'
  printf 'BRIEF_UUID=\n'
  printf 'SIZE=\n'
  printf 'TYPE=\n'
  printf "ACCEPTANCE_JSON='[]'\n"
  exit 0
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }

BRIEF_PATH=""
BRIEF_UUID=""
SIZE=""
TYPE=""
ACCEPTANCE_JSON='[]'

# Preferred surface: post-2.6 YAML via query-plans.sh. Matches briefs by
# legacy_task_id (carried on migrated briefs) and filters to dispatchable
# states. yq pulls typed fields.
if command -v yq >/dev/null 2>&1; then
  briefs_dir=$(resolve_briefs_dir_for "$PROJECT")
  if [ -d "$briefs_dir" ]; then
    # Walk all briefs carrying this legacy_task_id; pick the first in a
    # dispatchable state. Re-briefs leave the old brief in `debriefed` and
    # mint a new one in `ready` — `head -1` alone could pick either by
    # filesystem order and mask the live brief behind a stale one, forcing
    # a legacy fallback even when a valid YAML brief exists.
    match=""
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      state=$(yq -r '.state // "null"' "$candidate" 2>/dev/null || echo null)
      case "$state" in
        ready|dispatched|draft) match="$candidate"; break ;;
      esac
    done < <(grep -l "^legacy_task_id: \"$TASK_ID\"$" "$briefs_dir"/*.yaml 2>/dev/null)
    if [ -n "$match" ]; then
      BRIEF_PATH="$match"
      BRIEF_UUID=$(yq -r '.id // ""' "$match" 2>/dev/null || echo "")
      SIZE=$(yq -r '.size // ""' "$match" 2>/dev/null || echo "")
      TYPE=$(yq -r '.type // ""' "$match" 2>/dev/null || echo "")
      ACCEPTANCE_JSON=$(yq -o=json -I=0 '.acceptance // []' "$match" 2>/dev/null || echo '[]')
    fi
  fi
fi

# Legacy fallback — one match suffices. plans/chanakya-tasks/<task-id>-*.md.
if [ -z "$BRIEF_PATH" ]; then
  legacy_tasks_dir="$(resolve_plans_dir_for "$PROJECT")/chanakya-tasks"
  if [ -d "$legacy_tasks_dir" ]; then
    legacy_match=$(ls "$legacy_tasks_dir"/"$TASK_ID"-*.md 2>/dev/null | head -1)
    if [ -n "$legacy_match" ]; then
      BRIEF_PATH="$legacy_match"
      # Make the fallback observable so the migration's long tail is visible.
      # Reason is `no_yaml_brief_for_legacy_id` — accurate: we grep briefs/ by
      # legacy_task_id, not via plans/index.yaml (which exists). The prior
      # `plans_index_missing` reason was a misnomer that drowned real legacy
      # pickups in happy-path noise; see issue #105 root-cause trace.
      emit_event_keyed achilles task legacy_artifact_read "$TASK_ID" \
        '{"domain":"briefs","reason":"no_yaml_brief_for_legacy_id","caller":"task-load-spec.sh"}' \
        >/dev/null 2>&1 || true
      # Extract size/type from the legacy markdown header (`Size: S`, `Type: feature`).
      SIZE=$(awk '
        /^Size:/ { sub(/^Size:[[:space:]]*/, ""); print tolower($0); exit }
        /^- \*\*Size:\*\*/ { sub(/^- \*\*Size:\*\*[[:space:]]*/, ""); print tolower($0); exit }
      ' "$legacy_match" 2>/dev/null | tr -d ' ' | head -c 16)
      TYPE=$(awk '
        /^Type:/ { sub(/^Type:[[:space:]]*/, ""); print tolower($0); exit }
        /^- \*\*Type:\*\*/ { sub(/^- \*\*Type:\*\*[[:space:]]*/, ""); print tolower($0); exit }
      ' "$legacy_match" 2>/dev/null | tr -d ' ' | head -c 32)
      # Legacy briefs don't carry acceptance as typed JSON; leave empty array.
      # The prose remains in the file the caller reads at BRIEF_PATH.
      ACCEPTANCE_JSON='[]'
    fi
  fi
fi

if [ -z "$BRIEF_PATH" ]; then
  cat >&2 <<EOF
error: no brief found for task-id '$TASK_ID'.
  Run \`/chanakya brief $TASK_ID\` to author one, or invoke \`/achilles\` (no
  task-id) for direct mode.
EOF
  exit 2
fi

# #263 — terminal-state guard. Brief-state filtering above (ready / dispatched
# / draft) covers post-migration briefs; the legacy markdown fallback has no
# equivalent guard, so a misclick or terminal-history retrieval re-runs a
# completed task — fresh worktree, second debrief, in build / push-tf modes
# a second TF push. Read task state from the YAML SSOT by legacy_task_id and
# refuse when terminal. ACHILLES_REOPEN=1 is the explicit user override —
# legacy escape hatch that mints a follow-up debrief on the existing task
# without recording reopen lineage. The formal path is `/chanakya reopen`
# (#252), which transitions the task to `reopened`, stamps reopen_reason,
# appends the prior debrief id to reopen_chain, and emits task_reopened so
# the next brief carries the round-2 context. Prefer the formal path when
# you need provenance; the env-var override remains for one-off recovery.
# Tasks that exist only in legacy markdown have no rich state to read; the
# guard skips silently in that case, preserving pre-2.6 behaviour.
if [ -z "${ACHILLES_REOPEN:-}" ] && command -v yq >/dev/null 2>&1; then
  tasks_dir=$(resolve_tasks_dir_for "$PROJECT")
  if [ -d "$tasks_dir" ]; then
    task_state=""
    while IFS= read -r task_yaml; do
      [ -z "$task_yaml" ] && continue
      task_state=$(yq -r '.state // ""' "$task_yaml" 2>/dev/null)
      [ -n "$task_state" ] && break
    done < <(grep -l "^legacy_task_id: \"$TASK_ID\"$" "$tasks_dir"/*.yaml 2>/dev/null)
    case "$task_state" in
      merged|user-verifying|verified|archived)
        cat >&2 <<EOF
error: task '$TASK_ID' is in terminal state '$task_state' — refusing to dispatch.
  A second dispatch on a completed task creates a duplicate worktree and a
  second debrief; in build / push-tf modes it can re-run a release action.
  Run \`/chanakya reopen $TASK_ID --reason="<text>"\` for a formal
  state-machine reopen (records reason, appends prior debrief to
  reopen_chain, emits task_reopened). Set ACHILLES_REOPEN=1 for the legacy
  override that mints a follow-up debrief without lineage — prefer the
  formal path when provenance matters.
EOF
        exit 5 ;;
    esac
  fi
fi

# Fill sensible defaults so the caller never trips on an empty var.
[ -z "$SIZE" ] && SIZE=m
[ -z "$TYPE" ] && TYPE=feature

printf 'TASK_MODE=brief\n'
printf 'BRIEF_PATH=%s\n' "$BRIEF_PATH"
printf 'BRIEF_UUID=%s\n' "$BRIEF_UUID"
printf 'SIZE=%s\n' "$SIZE"
printf 'TYPE=%s\n' "$TYPE"
# Single-quote the JSON to survive eval without re-escaping internal quotes.
# ACCEPTANCE_JSON is producer-controlled (yq output); no single quotes possible.
printf "ACCEPTANCE_JSON='%s'\n" "$ACCEPTANCE_JSON"
