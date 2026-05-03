#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t field-review-lint.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

LINT="$ROOT/scripts/lint-field-review-surfaces.sh"

mkdir -p "$TMPROOT/good" "$TMPROOT/bad"

cat > "$TMPROOT/good/non-review.md" <<'MD'
# Worker spawn

The worker launches `claude -p "/achilles T123"` for a fresh task context.
MD

cat > "$TMPROOT/good/wrapper-doc.md" <<'MD'
# Review wrapper

Do not hand-compose raw `claude -p` / `codex exec` calls for sibling-host review; use `scripts/phase-review.sh`.

Emergency/debug-only bypass: `STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1` is user-controlled and must be recorded.
MD

cat > "$TMPROOT/good/allow.md" <<'MD'
# Fixture

<!-- lint-field-review:allow next-line — fixture documents the banned review command shape -->
Run claude -p "review this plan" for the synthetic bad case.
MD

cat > "$TMPROOT/bad/raw-claude.md" <<'MD'
# Planner review

Run claude -p "review this phase plan" before the architect starts.
MD

cat > "$TMPROOT/bad/raw-codex.yaml" <<'YAML'
acceptance:
  - Run codex exec "review this outcome" as the sibling-host reviewer.
YAML

cat > "$TMPROOT/bad/silent-bypass.md" <<'MD'
# Review escape

Run STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1 codex exec "review this plan".
MD

"$LINT" "$TMPROOT/good" >"$TMPROOT/good.out" 2>"$TMPROOT/good.err"

if "$LINT" "$TMPROOT/bad" >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  printf 'FAIL: lint accepted raw field-agent review host commands\n' >&2
  exit 1
fi

grep -q 'E_FIELD_REVIEW_RAW_HOST:.*raw-claude.md' "$TMPROOT/bad.out"
grep -q 'E_FIELD_REVIEW_RAW_HOST:.*raw-codex.yaml' "$TMPROOT/bad.out"
grep -q 'E_FIELD_REVIEW_BYPASS:.*silent-bypass.md' "$TMPROOT/bad.out"

printf 'PASS: field review surface lint blocks raw review host commands\n'
