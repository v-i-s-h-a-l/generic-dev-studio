#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"
# shellcheck source=scripts/lib-manager-context-header.sh
. "$ROOT/scripts/lib-manager-context-header.sh"

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
  # `--to dev-studio` is a common shorthand for the studio destination; normalize
  # so it routes through the studio-feedback path instead of being treated as a
  # project slug literal (which would write a project ingest dir named
  # "dev-studio"). See #822.
  if [ "$to_project" = "dev-studio" ]; then
    to_project=generic-dev-studio
  fi
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
artifact_root="$(resolve_project_ingest_root_for "$destination_project")"
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

# Render the always-on manager context header as a JSON object so the host
# surface can prompt the user with branch state + branch-policy fields before
# any ingest write. The header is informational; --scope / --to remain the
# user-controlled override surface and the host is expected to display the
# resolved context with the resolver's output. The pre-flight reuses the same
# branch resolution primitives wired into manifest schema v2 (T-R002), so
# ingest and plan-chain agree on which branch the work is anchored to.
context_header_json=$(manager_context_header_emit_json "$source_root" 2>/dev/null || printf 'null')
[ -n "$context_header_json" ] || context_header_json=null

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
  --argjson manager_context_header "$context_header_json" \
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
    local_ingest_policy: "project-profile",
    manager_context_header: $manager_context_header,
    source_branch_preflight: (
      if $manager_context_header == null then null
      else {
        kind: "ingest-source-branch-preflight",
        schema_version: 1,
        prompt_action: "confirm-or-override",
        current_branch: $manager_context_header.current_branch,
        base_ref: $manager_context_header.base_ref,
        base_sha: $manager_context_header.base_sha,
        dirty: $manager_context_header.dirty,
        on_protected_base: $manager_context_header.on_protected_base,
        policy: $manager_context_header.policy,
        override_flags: ["--scope studio", "--scope project", "--to <project-slug>"]
      }
      end
    )
  }'
