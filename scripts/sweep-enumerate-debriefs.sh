#!/usr/bin/env bash
# sweep-enumerate-debriefs.sh — Step 0 of the inbox sweep.
#
# Enumerates unprocessed debrief artifacts under plans/debriefs/*.yaml with
# state=emitted. Classifies each by kind and prints one tab-separated triple
# per line:
#
#   <kind>\t<path>\tyaml
#
#   kind ∈ {task-debrief, manual-build-check, release, direct-debrief}
#
# (The trailing `yaml` column is retained for caller back-compat — the legacy
# markdown inbox surface was archived under #245 A.4 and no longer enumerates
# here. The column always reads `yaml` post-flip.)
#
# Empty output is valid — exits 0 unconditionally so the caller can
# short-circuit on an empty sweep.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0

# Glob plans/debriefs/*.yaml; filter to state=emitted (missing `state` reads
# as emitted for pre-2.0.1 back-compat per inbox-sweep.md).
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
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

exit 0
