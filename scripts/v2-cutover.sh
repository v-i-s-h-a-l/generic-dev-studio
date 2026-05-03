#!/usr/bin/env bash
# v2-cutover.sh - validate and report Studio v2 A9 cutover state.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/core/v2/cutover/manifest.yaml"
FORWARDERS="$REPO_ROOT/core/v2/skills/dev-studio/forwarders.yaml"
ALLOW_ROLLED_BACK=0
VALIDATE=0
STATUS=0
JSON=0

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/v2-cutover.sh --validate [--allow-rolled-back]
  scripts/v2-cutover.sh --status [--json]

Validates the A9 archive, traffic-switch, parity, and rollback manifest without
moving v1 files. A10 owns deletion after the stability window.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --validate) VALIDATE=1; shift ;;
    --status) STATUS=1; shift ;;
    --json) JSON=1; shift ;;
    --allow-rolled-back) ALLOW_ROLLED_BACK=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ "$VALIDATE" -eq 1 ] || [ "$STATUS" -eq 1 ] || usage
command -v yq >/dev/null 2>&1 || { printf 'v2-cutover: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'v2-cutover: jq required\n' >&2; exit 2; }

yaml_has_key() {
  yq -e "has(\"$2\")" "$1" >/dev/null 2>&1
}

require_key() {
  yaml_has_key "$1" "$2" || {
    printf 'v2-cutover: %s missing %s\n' "${1#"$REPO_ROOT/"}" "$2" >&2
    return 1
  }
}

manifest_status() {
  yq -r '.status' "$MANIFEST"
}

forwarder_status() {
  yq -r '.transition.cutover_status' "$FORWARDERS"
}

validate_cutover() {
  local key status fwd_status false_count evidence
  [ -f "$MANIFEST" ] || { printf 'v2-cutover: missing manifest: %s\n' "$MANIFEST" >&2; return 1; }
  [ -f "$FORWARDERS" ] || { printf 'v2-cutover: missing forwarders: %s\n' "$FORWARDERS" >&2; return 1; }

  for key in schema_version kind parent_issue leaf_issue status archive traffic_switch parity rollback carryover; do
    require_key "$MANIFEST" "$key"
  done

  [ "$(yq -r '.schema_version' "$MANIFEST")" = "1" ] || { printf 'v2-cutover: unsupported schema_version\n' >&2; return 1; }
  [ "$(yq -r '.kind' "$MANIFEST")" = "studio-v2-cutover" ] || { printf 'v2-cutover: unsupported kind\n' >&2; return 1; }
  [ "$(yq -r '.parent_issue' "$MANIFEST")" = "444" ] || { printf 'v2-cutover: parent_issue must be 444\n' >&2; return 1; }
  [ "$(yq -r '.leaf_issue' "$MANIFEST")" = "527" ] || { printf 'v2-cutover: leaf_issue must be 527\n' >&2; return 1; }

  status=$(manifest_status)
  case "$status" in
    cut-over) ;;
    rolled-back)
      [ "$ALLOW_ROLLED_BACK" -eq 1 ] || { printf 'v2-cutover: rolled back; pass --allow-rolled-back for rollback validation\n' >&2; return 1; }
      ;;
    *) printf 'v2-cutover: status must be cut-over or rolled-back, got %s\n' "$status" >&2; return 1 ;;
  esac

  [ "$(yq -r '.traffic_switch.primary_invocation' "$MANIFEST")" = "/dev-studio" ] || {
    printf 'v2-cutover: primary invocation must be /dev-studio\n' >&2; return 1;
  }
  [ "$(yq -r '.traffic_switch.source_of_truth' "$MANIFEST")" = "core/v2/skills/dev-studio/forwarders.yaml" ] || {
    printf 'v2-cutover: unexpected traffic source of truth\n' >&2; return 1;
  }
  [ "$(yq -r '.archive.legacy_root' "$MANIFEST")" = "legacy/v1" ] || {
    printf 'v2-cutover: legacy archive root must be legacy/v1\n' >&2; return 1;
  }

  fwd_status=$(forwarder_status)
  if [ "$status" = "cut-over" ]; then
    [ "$fwd_status" = "cut-over" ] || { printf 'v2-cutover: forwarders are not cut over\n' >&2; return 1; }
    false_count=$(yq -r '[.forwarders[] | select(.runtime_cutover != true)] | length' "$FORWARDERS")
    [ "$false_count" = "0" ] || { printf 'v2-cutover: %s forwarders are not runtime_cutover=true\n' "$false_count" >&2; return 1; }
  fi
  if [ "$status" = "rolled-back" ]; then
    [ "$fwd_status" = "not-cut-over" ] || { printf 'v2-cutover: rollback requires forwarders not-cut-over\n' >&2; return 1; }
  fi

  while IFS= read -r evidence; do
    [ -n "$evidence" ] || continue
    case "$evidence" in
      core/v2/manager/proof-of-life.yaml|core/v2/roles/worker.yaml|core/v2/roles/reviewer.yaml|core/v2/roles/perf.yaml)
        ;;
      *) printf 'v2-cutover: unexpected parity evidence path: %s\n' "$evidence" >&2; return 1 ;;
    esac
  done < <(yq -r '.parity.golden_scenarios[].evidence' "$MANIFEST")

  printf 'v2-cutover: ok\n' >&2
}

print_status() {
  if [ "$JSON" -eq 1 ]; then
    jq -n \
      --arg status "$(manifest_status)" \
      --arg forwarders "$(forwarder_status)" \
      --arg primary "$(yq -r '.traffic_switch.primary_invocation' "$MANIFEST")" \
      '{status:$status, forwarders:$forwarders, primary_invocation:$primary}'
  else
    printf 'status: %s\n' "$(manifest_status)"
    printf 'forwarders: %s\n' "$(forwarder_status)"
    printf 'primary_invocation: %s\n' "$(yq -r '.traffic_switch.primary_invocation' "$MANIFEST")"
  fi
}

if [ "$VALIDATE" -eq 1 ]; then
  validate_cutover
fi
if [ "$STATUS" -eq 1 ]; then
  print_status
fi
