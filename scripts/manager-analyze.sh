#!/usr/bin/env bash
# manager-analyze.sh — studio-side analysis entrypoint.
#
# Analyze is intentionally studio-repo scoped. Project debrief/report syncing
# mutates project task state and belongs to manager-reconcile.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

CWD="${PWD:-.}"
APPLY=1
EXTRA_ARGS=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-analyze.sh [--cwd <dir>] [--apply|--dry-run]

Run from generic-dev-studio only. To sync project debriefs/reports into a
project task ledger, use scripts/manager-reconcile.sh from that project.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) CWD="${2:?--cwd requires a value}"; shift 2 ;;
    --cwd=*) CWD="${1#--cwd=}"; shift ;;
    --scope|--scope=*)
      printf 'manager-analyze: --scope is retired; run from generic-dev-studio, or use manager-reconcile for project reports\n' >&2
      exit 2
      ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) usage ;;
    --*) EXTRA_ARGS+=("$1"); shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

project_root=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$CWD")
project_slug=$(basename "$project_root")

if [ ! -f "$project_root/core/v2/skills/dev-studio/SKILL.md" ] \
    || [ ! -f "$project_root/scripts/analyze-feedback-ingest.sh" ]; then
  printf 'manager-analyze: refusing project checkout %s; run /dev-studio manager reconcile for project debrief/report sync\n' "$project_slug" >&2
  printf 'manager-analyze: run analyze from the generic-dev-studio repo for studio-side analysis and feedback triage\n' >&2
  exit 2
fi

data_home="${HOME:-}"
case "${STUDIO_BYPASS_ANALYZE_LOGIN_HOME:-0}" in
  1|true|TRUE|yes|YES) ;;
  *)
    login_home=$(resolve_user_login_home 2>/dev/null || true)
    if [ -n "$login_home" ] && [ -d "$login_home" ]; then
      data_home="$login_home"
    fi
    ;;
esac

inbox_root=$(HOME="$data_home" resolve_feedback_inbox_root)
export HOME="$data_home"
if [ "$APPLY" = "1" ]; then
  if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    exec "$SCRIPT_DIR/analyze-feedback-ingest.sh" --apply --inbox-root "$inbox_root" "${EXTRA_ARGS[@]}"
  fi
  exec "$SCRIPT_DIR/analyze-feedback-ingest.sh" --apply --inbox-root "$inbox_root"
fi
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  exec "$SCRIPT_DIR/analyze-feedback-ingest.sh" --inbox-root "$inbox_root" "${EXTRA_ARGS[@]}"
fi
exec "$SCRIPT_DIR/analyze-feedback-ingest.sh" --inbox-root "$inbox_root"
