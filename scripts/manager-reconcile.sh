#!/usr/bin/env bash
# manager-reconcile.sh — sync project reports into the project ledger.
#
# Reconcile mutates project task state from emitted debrief/report artifacts.
# Studio-side analysis and feedback triage stay in manager-analyze.sh.

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
  scripts/manager-reconcile.sh [--cwd <dir>] [--apply|--dry-run]

Run from a project checkout to ingest emitted debrief/report artifacts into
that project's task ledger. Studio feedback analysis belongs to manager analyze.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) CWD="${2:?--cwd requires a value}"; shift 2 ;;
    --cwd=*) CWD="${1#--cwd=}"; shift ;;
    --scope|--scope=*)
      printf 'manager-reconcile: --scope is not supported; reconcile always targets the current project ledger\n' >&2
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

if [ -f "$project_root/core/v2/skills/dev-studio/SKILL.md" ] \
    && [ -f "$project_root/scripts/analyze-feedback-ingest.sh" ]; then
  printf 'manager-reconcile: refusing generic-dev-studio; run from a project checkout, or use manager analyze for studio-side analysis\n' >&2
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

json_escape() {
  jq -Rn --arg s "$1" '$s'
}

tmpdir=$(mktemp -d -t manager-reconcile.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
queue="$tmpdir/debrief-queue.tsv"
errors="$tmpdir/debrief-enumerate.err"
processed="$tmpdir/processed.jsonl"
failed="$tmpdir/failed.jsonl"
touch "$processed" "$failed"

if ! HOME="$data_home" ACHILLES_PROJECT="$project_slug" "$SCRIPT_DIR/sweep-enumerate-debriefs.sh" >"$queue" 2>"$errors"; then
  printf 'manager-reconcile: debrief enumeration failed for %s\n' "$project_slug" >&2
  cat "$errors" >&2
  exit 2
fi

before_count=$(wc -l < "$queue" | tr -d ' ')

if [ "$APPLY" = "1" ]; then
  while IFS=$'\t' read -r subcmd source _format; do
    [ -n "${subcmd:-}" ] || continue
    if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
      if HOME="$data_home" ACHILLES_PROJECT="$project_slug" "$SCRIPT_DIR/sweep-ingest.sh" "$subcmd" "$source" "${EXTRA_ARGS[@]}" >/dev/null 2>"$tmpdir/ingest.err"; then
        ingest_rc=0
      else
        ingest_rc=$?
      fi
    else
      if HOME="$data_home" ACHILLES_PROJECT="$project_slug" "$SCRIPT_DIR/sweep-ingest.sh" "$subcmd" "$source" >/dev/null 2>"$tmpdir/ingest.err"; then
        ingest_rc=0
      else
        ingest_rc=$?
      fi
    fi
    if [ "$ingest_rc" -eq 0 ]; then
      printf '{"subcommand":%s,"source":%s,"status":"ingested"}\n' \
        "$(json_escape "$subcmd")" "$(json_escape "$source")" >> "$processed"
    else
      err=$(sed -n '1,20p' "$tmpdir/ingest.err" | paste -sd ' ' -)
      printf '{"subcommand":%s,"source":%s,"status":"failed","error":%s}\n' \
        "$(json_escape "$subcmd")" "$(json_escape "$source")" "$(json_escape "$err")" >> "$failed"
    fi
  done < "$queue"
fi

after_queue="$tmpdir/debrief-queue-after.tsv"
after_errors="$tmpdir/debrief-enumerate-after.err"
HOME="$data_home" ACHILLES_PROJECT="$project_slug" "$SCRIPT_DIR/sweep-enumerate-debriefs.sh" >"$after_queue" 2>"$after_errors" || true
after_count=$(wc -l < "$after_queue" | tr -d ' ')
processed_json=$(jq -s '.' "$processed")
failed_json=$(jq -s '.' "$failed")

jq -n \
  --arg mode "$([ "$APPLY" = "1" ] && printf apply || printf dry-run)" \
  --arg project "$project_slug" \
  --arg cwd "$project_root" \
  --argjson before "${before_count:-0}" \
  --argjson after "${after_count:-0}" \
  --argjson processed "$processed_json" \
  --argjson failed "$failed_json" \
  '{
    schema_version: 1,
    kind: "manager_reconcile_project_reports",
    mode: $mode,
    scope: "project",
    project: $project,
    project_root: $cwd,
    debrief_queue_count_before: $before,
    debrief_queue_count_after: $after,
    processed_count: ($processed | length),
    failed_count: ($failed | length),
    processed: $processed,
    failed: $failed
  }'
