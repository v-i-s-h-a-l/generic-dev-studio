#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t argus-verdict-format-022.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="argus-verdict-format-022"
TASK_UUID="0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11"
PROJECT_ROOT="$HOME/.dev-studio/$ACHILLES_PROJECT"
LEGACY_REVIEW="$TMPROOT/review_T022_quality.md"

mkdir -p "$PROJECT_ROOT/plans/tasks"
cat > "$PROJECT_ROOT/plans/tasks/$TASK_UUID.yaml" <<'YAML'
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11
legacy_task_id: "T022"
state: in-review
updated_at: 2026-05-05T00:00:00Z
links: {reviews: []}
YAML

DRY_RUN=1 "$ROOT/scripts/argus-emit-verdict.sh" T022 approved '[]' \
  --task-uuid "$TASK_UUID" \
  --review-file-legacy "$LEGACY_REVIEW" \
  >/dev/null

grep -q '^verdict: approved$' "$LEGACY_REVIEW" \
  || fail "legacy review did not use canonical lowercase verdict line"

sed -n '1,5p' "$LEGACY_REVIEW" | grep -q '^verdict: approved$' \
  || fail "canonical verdict was not in YAML frontmatter"

if grep -qE '^(Verdict:|\\*\\*Verdict:\\*\\*)' "$LEGACY_REVIEW"; then
  fail "legacy review emitted a non-canonical verdict line"
fi

printf 'PASS: argus verdict format\n'
