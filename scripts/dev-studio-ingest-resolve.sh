#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"

usage() {
  cat >&2 <<'EOF'
usage: dev-studio-ingest-resolve.sh [--cwd <path>] [--message-file <path>] [--scope studio|project] [--to <project-slug>]

Resolves /dev-studio manager ingest destination as structured JSON.
EOF
}

cwd=$PWD
message_file=
scope=
to_project=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      cwd=$2
      shift 2
      ;;
    --message-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      message_file=$2
      shift 2
      ;;
    --scope)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      scope=$2
      shift 2
      ;;
    --to)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      to_project=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$scope" in
  ""|studio|project) ;;
  *)
    printf 'error: --scope must be studio or project\n' >&2
    exit 2
    ;;
esac

[ -d "$cwd" ] || {
  printf 'error: --cwd does not exist or is not a directory: %s\n' "$cwd" >&2
  exit 1
}

if [ -n "$message_file" ] && [ ! -r "$message_file" ]; then
  printf 'error: --message-file is not readable: %s\n' "$message_file" >&2
  exit 1
fi

source_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$cwd")
source_project=$(basename "$source_root")
destination_project=$source_project

if [ -n "$to_project" ]; then
  destination_project=$to_project
elif [ "$scope" = "studio" ]; then
  destination_project=generic-dev-studio
fi

resolved_scope=project
if [ "$destination_project" = "generic-dev-studio" ]; then
  resolved_scope=studio
fi

if [ "$scope" = "studio" ] && [ "$resolved_scope" != "studio" ]; then
  printf 'error: --scope studio conflicts with --to %s\n' "$destination_project" >&2
  exit 2
fi

if [ "$scope" = "project" ] && [ "$resolved_scope" = "studio" ]; then
  printf 'error: --scope project conflicts with studio destination %s\n' "$destination_project" >&2
  exit 2
fi

artifact_kind=project-ingest
artifact_root="$(resolve_project_root_for "$destination_project")/ingest"
public_issue_repo=null
requires_privacy_scrub=false

if [ "$resolved_scope" = "studio" ]; then
  artifact_kind=studio-ingest
  artifact_root="$(resolve_feedback_inbox_for "$source_project")"
  public_issue_repo='"v-i-s-h-a-l/generic-dev-studio"'
  if [ "$source_project" != "generic-dev-studio" ]; then
    requires_privacy_scrub=true
  fi
fi

jq -n \
  --arg source_project "$source_project" \
  --arg source_root "$source_root" \
  --arg destination_project "$destination_project" \
  --arg scope "$resolved_scope" \
  --arg artifact_kind "$artifact_kind" \
  --arg artifact_root "$artifact_root" \
  --argjson public_issue_repo "$public_issue_repo" \
  --argjson requires_privacy_scrub "$requires_privacy_scrub" \
  --arg message_file "$message_file" \
  '{
    kind: "dev-studio-ingest-route",
    schema_version: 1,
    source_project: $source_project,
    source_root: $source_root,
    destination_project: $destination_project,
    scope: $scope,
    artifact_kind: $artifact_kind,
    artifact_root: $artifact_root,
    public_issue_repo: $public_issue_repo,
    requires_privacy_scrub: $requires_privacy_scrub,
    message_file: (if $message_file == "" then null else $message_file end),
    local_ingest_policy: "project-profile"
  }'
