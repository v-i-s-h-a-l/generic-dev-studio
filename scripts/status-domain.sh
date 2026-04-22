#!/usr/bin/env bash
# status-domain.sh — rounds + releases status one-liners for /chanakya status.
#
# Sub-commands print a single human-readable status line on stdout. No events
# emitted; pure read-over-derivation. Post-2.6 prefers YAML sources via
# query-plans.sh; legacy markdown is Phase 2.6 transition fallback.
#
# Usage:
#   scripts/status-domain.sh <rounds|releases>

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

cmd="${1:-}"
case "$cmd" in
  rounds|releases) ;;
  "") printf 'usage: status-domain.sh <rounds|releases>\n' >&2; exit 2 ;;
  *)  printf 'unknown subcommand: %s\n' "$cmd" >&2; exit 2 ;;
esac

PROJECT=$(resolve_project 2>/dev/null) || exit 2
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")

rounds_status() {
  local rounds_dir="$PROJECT_ROOT/plans/rounds"
  local latest_yaml latest_md count num_yaml num_md

  # Prefer YAML; legacy fallback.
  if [ -d "$rounds_dir" ]; then
    num_yaml=$(find "$rounds_dir" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')
  else
    num_yaml=0
  fi

  if [ "$num_yaml" -gt 0 ]; then
    # Latest round by round_number.
    latest_yaml=$(yq -r 'select(.schema_version.name == "round") | .round_number // 0' "$rounds_dir"/*.yaml 2>/dev/null | sort -n | tail -1)
    if [ -z "$latest_yaml" ] || [ "$latest_yaml" = "0" ]; then
      printf 'No user-testing rounds yet.\n'
      return 0
    fi
    # Pull cases count for the latest round — cases: [] means migration-stub; active rounds carry state.
    local latest_file
    latest_file=$(grep -lE "^round_number: $latest_yaml$" "$rounds_dir"/*.yaml 2>/dev/null | head -1)
    if [ -n "$latest_file" ]; then
      local state cases_total pass pending
      state=$(yq -r '.state // "unknown"' "$latest_file" 2>/dev/null)
      cases_total=$(yq -r '.summary.cases_total // (.cases | length)' "$latest_file" 2>/dev/null)
      pass=$(yq -r '.summary.pass // 0' "$latest_file" 2>/dev/null)
      pending=$(yq -r '.summary.pending // 0' "$latest_file" 2>/dev/null)
      if [ "$state" = "closed" ] || [ "${pending:-0}" = "0" ] && [ "${cases_total:-0}" != "0" ]; then
        printf 'Round %s completed — consider --promote to feed into review-feedback, or generate a new round.\n' "$latest_yaml"
      else
        printf 'Round %s is in progress (%s/%s cases checked).\n' "$latest_yaml" "${pass:-0}" "${cases_total:-?}"
      fi
    else
      printf 'Round %s present; state unreadable.\n' "$latest_yaml"
    fi
    return 0
  fi

  # Legacy fallback.
  local legacy_dir="$PROJECT_ROOT/plans/user-testing-rounds"
  if [ ! -d "$legacy_dir" ]; then
    printf 'No user-testing rounds yet.\n'
    return 0
  fi
  num_md=$(find "$legacy_dir" -maxdepth 1 -name 'user-testing-round*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$num_md" = "0" ]; then
    printf 'No user-testing rounds yet.\n'
    return 0
  fi
  # Highest N; parse checked-vs-total from the file body.
  latest_md=$(find "$legacy_dir" -maxdepth 1 -name 'user-testing-round*.md' -type f 2>/dev/null \
    | sed -E 's|.*/user-testing-round([0-9]+)\.md|\1|' | sort -n | tail -1)
  local f="$legacy_dir/user-testing-round${latest_md}.md"
  local total checked
  total=$(grep -c '^\- \[ \]\|^\- \[x\]' "$f" 2>/dev/null || echo 0)
  checked=$(grep -c '^\- \[x\]' "$f" 2>/dev/null || echo 0)
  if [ "$checked" = "$total" ] && [ "$total" != "0" ]; then
    printf 'Round %s completed — consider --promote to feed into review-feedback, or generate a new round.\n' "$latest_md"
  else
    printf 'Round %s is in progress (%s/%s cases checked).\n' "$latest_md" "$checked" "$total"
  fi
}

releases_status() {
  local releases_dir="$PROJECT_ROOT/plans/releases"
  local latest_tf latest_as

  if [ -d "$releases_dir" ]; then
    # Most-recent per channel by build_number (numeric desc).
    latest_tf=$(yq -r 'select(.channel == "testflight") | "\(.build_number) \(.version) \(.released_at // .submitted_at // "—")"' \
      "$releases_dir"/*.yaml 2>/dev/null | sort -rn | head -1)
    latest_as=$(yq -r 'select(.channel == "appstore") | "\(.build_number) \(.version) \(.released_at // .submitted_at // "—")"' \
      "$releases_dir"/*.yaml 2>/dev/null | sort -rn | head -1)
  fi

  local msg=""
  if [ -n "${latest_tf:-}" ]; then
    local tf_build tf_version tf_date
    read -r tf_build tf_version tf_date <<<"$latest_tf"
    msg="Latest TestFlight: build $tf_build (v$tf_version, $tf_date)."
  fi
  if [ -n "${latest_as:-}" ]; then
    local as_build as_version as_date
    read -r as_build as_version as_date <<<"$latest_as"
    msg="${msg:+$msg }Latest App Store: build $as_build (v$as_version, $as_date)."
  fi

  # Tasks merged since the last TestFlight — count YAML tasks in state merged
  # or verified whose links.release is null (none of them shipped to TF yet).
  local merged_since=0
  if [ -d "$PROJECT_ROOT/plans/tasks" ]; then
    merged_since=$(yq -r 'select(.state == "merged" or .state == "user-verifying" or .state == "verified") | select(.links.release == null) | .id' \
      "$PROJECT_ROOT/plans/tasks"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
  fi

  if [ -z "$msg" ]; then
    printf 'No releases yet.\n'
    return 0
  fi

  if [ "$merged_since" -gt 0 ]; then
    msg="$msg $merged_since task(s) merged since last TestFlight — consider /achilles push-tf."
  fi

  printf '%s\n' "$msg"
}

case "$cmd" in
  rounds)   rounds_status ;;
  releases) releases_status ;;
esac
