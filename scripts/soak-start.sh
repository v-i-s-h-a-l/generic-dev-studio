#!/usr/bin/env bash
# soak-start.sh — initialise the #245 A.2 dual-write soak for a project.
#
# Writes two files under ~/.dev-studio/<project>/state/:
#
#   env.sh             `export DUAL_WRITE_MODE=yaml-only`. Sourced by
#                      lib-paths.sh::_lp_load_project_env on every studio
#                      script invocation in this project. Effect: writers
#                      stop dual-writing the legacy markdown surface.
#
#   soak-start.json    Marker the reporter (soak-status.sh) reads to compute
#                      progress against the issue-#245 exit criteria. Carries
#                      the start timestamp + the audit-known set of expected
#                      `legacy_artifact_read` domains.
#
# Idempotent: refuses to overwrite a live soak unless --force is passed.
#
# Usage:
#   scripts/soak-start.sh <project-slug>
#   scripts/soak-start.sh <project-slug> --force

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    -*) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    *)  if [ -z "$PROJECT" ]; then PROJECT="$arg"; else printf 'extra arg: %s\n' "$arg" >&2; exit 2; fi ;;
  esac
done

if [ -z "$PROJECT" ]; then
  printf 'usage: %s <project-slug> [--force]\n' "$(basename "$0")" >&2
  exit 2
fi

PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
STATE_DIR="$PROJECT_ROOT/state"
ENV_FILE="$STATE_DIR/env.sh"
MARKER="$STATE_DIR/soak-start.json"

if [ ! -d "$PROJECT_ROOT" ]; then
  printf 'soak-start: project root missing: %s\n' "$PROJECT_ROOT" >&2
  printf 'soak-start: bootstrap the project first (scripts/bootstrap.sh).\n' >&2
  exit 1
fi

if [ -f "$MARKER" ] && [ "$FORCE" -ne 1 ]; then
  printf 'soak-start: soak already active for %s.\n' "$PROJECT" >&2
  printf 'soak-start: existing marker → %s\n' "$MARKER" >&2
  printf 'soak-start: pass --force to overwrite (resets the soak window).\n' >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

# env.sh — the load-bearing flip. Sourced by lib-paths.sh on script entry.
cat > "$ENV_FILE" <<'EOF'
# Per-project env overrides for the studio. Sourced by lib-paths.sh::_lp_load_project_env
# at the top of every ledger-touching script. Set here, not in shell rc, so the
# scope is one project (no leak to other ~/.dev-studio/<project>/ workspaces).
#
# DUAL_WRITE_MODE=yaml-only — written by scripts/soak-start.sh as part of
# #245 A.2 (dual-write soak). Removed by A.5 cleanup once A.3 has flipped the
# in-code default.
export DUAL_WRITE_MODE=yaml-only
EOF

# soak-start.json — the reporter's starting boundary.
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$MARKER" <<EOF
{
  "issue": 245,
  "stage": "A.2",
  "started_at": "$STARTED_AT",
  "started_by": "scripts/soak-start.sh",
  "project": "$PROJECT",
  "exit_criteria": {
    "task_cycles_min": 30,
    "release_ceremonies_min": 1,
    "sweep_runs_min": 1,
    "unaccounted_legacy_domains": 0
  },
  "expected_legacy_domains": [
    "tests",
    "briefs",
    "candidates",
    "build_debt",
    "next_task_id"
  ],
  "exit_criteria_source": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/245#A.2"
}
EOF

printf 'soak-start: project=%s\n' "$PROJECT"
printf 'soak-start: env.sh   → %s\n' "$ENV_FILE"
printf 'soak-start: marker   → %s\n' "$MARKER"
printf 'soak-start: started_at=%s\n' "$STARTED_AT"
printf 'soak-start: DUAL_WRITE_MODE=yaml-only is live for new sessions in this project.\n'
printf 'soak-start: check progress with: scripts/soak-status.sh %s\n' "$PROJECT"
