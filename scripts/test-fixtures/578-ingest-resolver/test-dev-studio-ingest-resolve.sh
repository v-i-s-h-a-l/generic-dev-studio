#!/usr/bin/env bash

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/dev-studio-ingest-resolve.sh"
TMPROOT=$(mktemp -d -t ingest-resolver.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

make_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
}

[ -x "$RUN" ] || fail "scripts/dev-studio-ingest-resolve.sh is not executable"

make_repo "$TMPROOT/generic-dev-studio"
make_repo "$TMPROOT/sample-app"
printf 'workflow gap\n' > "$TMPROOT/message.md"

studio_json=$(HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/generic-dev-studio")
printf '%s\n' "$studio_json" | jq -e \
  --arg home "$TMPROOT/home" \
  '.kind == "dev-studio-ingest-route"
   and .schema_version == 1
   and .source_project == "generic-dev-studio"
   and .destination_project == "generic-dev-studio"
   and .scope == "studio"
   and .artifact_kind == "studio-ingest"
   and .artifact_root == ($home + "/.dev-studio/generic-dev-studio/feedback-inbox/generic-dev-studio")
   and .public_issue_repo == "v-i-s-h-a-l/generic-dev-studio"
   and .requires_privacy_scrub == false
   and .local_ingest_policy == "project-profile"' >/dev/null || {
  printf '%s\n' "$studio_json" >&2
  fail "studio repo default route was not Forge/Studio"
}

project_json=$(HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/sample-app")
printf '%s\n' "$project_json" | jq -e \
  --arg home "$TMPROOT/home" \
  '.source_project == "sample-app"
   and .destination_project == "sample-app"
   and .scope == "project"
   and .artifact_kind == "project-ingest"
   and .artifact_root == ($home + "/.dev-studio/sample-app/ingest")
   and .public_issue_repo == null
   and .requires_privacy_scrub == false' >/dev/null || {
  printf '%s\n' "$project_json" >&2
  fail "project repo default route was not project-local"
}

cross_scope_json=$(HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/sample-app" --scope studio --message-file "$TMPROOT/message.md")
printf '%s\n' "$cross_scope_json" | jq -e \
  --arg msg "$TMPROOT/message.md" \
  '.source_project == "sample-app"
   and .destination_project == "generic-dev-studio"
   and .scope == "studio"
   and .artifact_kind == "studio-ingest"
   and .public_issue_repo == "v-i-s-h-a-l/generic-dev-studio"
   and .requires_privacy_scrub == true
   and .message_file == $msg' >/dev/null || {
  printf '%s\n' "$cross_scope_json" >&2
  fail "--scope studio did not route cross-context to Forge"
}

cross_to_json=$(HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/sample-app" --to generic-dev-studio)
printf '%s\n' "$cross_to_json" | jq -e \
  '.destination_project == "generic-dev-studio"
   and .scope == "studio"
   and .requires_privacy_scrub == true' >/dev/null || {
  printf '%s\n' "$cross_to_json" >&2
  fail "--to generic-dev-studio did not route cross-context to Forge"
}

explicit_project_json=$(HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/sample-app" --to other-app)
printf '%s\n' "$explicit_project_json" | jq -e \
  '.destination_project == "other-app"
   and .scope == "project"
   and .artifact_kind == "project-ingest"
   and .requires_privacy_scrub == false' >/dev/null || {
  printf '%s\n' "$explicit_project_json" >&2
  fail "--to other-app did not remain project-scoped"
}

if HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/sample-app" --scope project --to generic-dev-studio >"$TMPROOT/ingest-conflict.out" 2>"$TMPROOT/ingest-conflict.err"; then
  fail "conflicting project scope and studio destination should fail"
fi
grep -q 'conflicts with studio destination' "$TMPROOT/ingest-conflict.err" || {
  cat "$TMPROOT/ingest-conflict.err" >&2
  fail "conflict error was not actionable"
}

if HOME="$TMPROOT/home" "$RUN" --cwd "$TMPROOT/generic-dev-studio" --scope project --to generic-dev-studio >"$TMPROOT/studio-conflict.out" 2>"$TMPROOT/studio-conflict.err"; then
  fail "explicit project scope and studio destination should fail in studio repo"
fi
grep -q 'conflicts with studio destination' "$TMPROOT/studio-conflict.err" || {
  cat "$TMPROOT/studio-conflict.err" >&2
  fail "studio conflict error was not actionable"
}

printf 'PASS: dev-studio ingest resolver\n'
