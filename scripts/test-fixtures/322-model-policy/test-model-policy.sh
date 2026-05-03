#!/usr/bin/env bash
# Regression coverage for provider-family reviewer model resolution.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t model-policy.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

catalog_out="$TMPROOT/catalog.out"
bash "$ROOT/scripts/check-model-catalog.sh" >"$catalog_out" 2>"$catalog_out.err"
catalog_rc=$?
assert "catalog validates" "[ '$catalog_rc' -eq 0 ]"

codex_out="$TMPROOT/codex.out"
bash "$ROOT/scripts/resolve-reviewer-model.sh" \
  --review-host codex-reviewer \
  --implementation-host claude-code >"$codex_out" 2>"$codex_out.err"
codex_rc=$?
assert "codex reviewer resolves for anthropic implementation" "[ '$codex_rc' -eq 0 ]"
assert "codex reviewer uses openai family" "grep -q '^REVIEWER_MODEL_PROVIDER_FAMILY=openai$' '$codex_out'"
assert "codex reviewer uses latest codex catalog model" "grep -q '^REVIEWER_MODEL_ID=gpt-5.5$' '$codex_out'"
assert "codex reviewer uses catalog reasoning" "grep -q '^REVIEWER_MODEL_REASONING_EFFORT=medium$' '$codex_out'"

claude_out="$TMPROOT/claude.out"
bash "$ROOT/scripts/resolve-reviewer-model.sh" \
  --review-host claude-reviewer \
  --implementation-host codex >"$claude_out" 2>"$claude_out.err"
claude_rc=$?
assert "claude reviewer resolves for openai implementation" "[ '$claude_rc' -eq 0 ]"
assert "claude reviewer uses anthropic family" "grep -q '^REVIEWER_MODEL_PROVIDER_FAMILY=anthropic$' '$claude_out'"
assert "claude reviewer uses opus" "grep -q '^REVIEWER_MODEL_ID=claude-opus-4-1-20250805$' '$claude_out'"

same_out="$TMPROOT/same.out"
if bash "$ROOT/scripts/resolve-reviewer-model.sh" \
    --review-host codex-reviewer \
    --implementation-host codex >"$same_out" 2>"$same_out.err"; then
  same_rc=0
else
  same_rc=$?
fi
assert "same-family reviewer blocks by default" "[ '$same_rc' -eq 3 ]"

bypass_out="$TMPROOT/bypass.out"
bash "$ROOT/scripts/resolve-reviewer-model.sh" \
  --review-host codex-reviewer \
  --implementation-host codex \
  --allow-same-family >"$bypass_out" 2>"$bypass_out.err"
bypass_rc=$?
assert "same-family bypass resolves explicitly" "[ '$bypass_rc' -eq 0 ]"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  sed -n '1,80p' "$catalog_out.err" >&2 || true
  sed -n '1,80p' "$codex_out.err" >&2 || true
  sed -n '1,80p' "$claude_out.err" >&2 || true
  sed -n '1,80p' "$same_out.err" >&2 || true
  exit 1
fi

printf 'PASS: model policy resolver\n'
