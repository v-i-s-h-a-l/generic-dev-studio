#!/usr/bin/env bash

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t review-budget.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# shellcheck source=scripts/lib-review-budget.sh
. "$ROOT/scripts/lib-review-budget.sh"

low_diff="$TMPROOT/low.diff"
printf 'diff --git a/docs/readme.md b/docs/readme.md\n+ok\n' > "$low_diff"
review_budget_policy_json pr "$low_diff" auto | jq -e '
  .mode == "diff-scoped" and .fast_path.eligible == true and .risk_triggers == []
' >/dev/null

risky_diff="$TMPROOT/risky.diff"
printf 'diff --git a/scripts/new.sh b/scripts/new.sh\n+ok\n' > "$risky_diff"
review_budget_policy_json pr "$risky_diff" auto | jq -e '
  .mode == "expanded" and (.risk_triggers | index("path:scripts/new.sh"))
' >/dev/null

large_diff="$TMPROOT/large.diff"
{
  printf 'diff --git a/docs/large.md b/docs/large.md\n'
  seq 1 10 | sed 's/^/+line /'
} > "$large_diff"
STUDIO_REVIEW_PAYLOAD_MAX_DIFF_LINES=3 review_budget_policy_json pr "$large_diff" auto | jq -e '
  .mode == "summarized" and .risk_level == "budget"
' >/dev/null

BIN="$TMPROOT/bin"
REPO="$TMPROOT/repo"
mkdir -p "$BIN" "$REPO"

cat > "$BIN/yq" <<'SH'
#!/usr/bin/env bash
expr="$2"
case "$expr" in
  *detect_binary*) printf 'codex\n' ;;
  *capabilities_path*) printf '.codex-reviewer/capabilities.yaml\n' ;;
  *) printf 'unexpected yq expression: %s\n' "$expr" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN/yq"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
case " $* " in
  *"smoke test"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || exit 3
if grep -q '"mode":"diff-scoped"' "$REVIEW_PAYLOAD"; then
  printf 'REVIEW_CONTEXT_FALLBACK=expanded\n'
  exit 0
fi
grep -q '"mode":"expanded"' "$REVIEW_PAYLOAD" || exit 4
grep -q 'Expanded repo review rules' "$REVIEW_PAYLOAD" || exit 5
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export CODEX_HOME="$HOME/.codex"
export STUDIO_REVIEWER_SMOKE_TIMEOUT_SEC=0
mkdir -p "$CODEX_HOME"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/docs"
printf 'one\n' > "$REPO/docs/readme.md"
git -C "$REPO" add docs/readme.md
git -C "$REPO" commit -qm initial
printf 'two\n' >> "$REPO/docs/readme.md"
git -C "$REPO" add docs/readme.md

if ! (cd "$REPO" && bash "$ROOT/scripts/pre-commit-review.sh" --review-host codex-reviewer >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  sed -n '1,120p' "$TMPROOT/out" >&2 || true
  sed -n '1,120p' "$TMPROOT/err" >&2 || true
  exit 1
fi

grep -q 'PRECOMMIT_REVIEW_VERDICT=approved' "$TMPROOT/out"
event_log=$(find "$HOME/.dev-studio" -type f -path '*/events/*.jsonl' | head -1)
[ -n "$event_log" ] || { printf 'missing event log\n' >&2; exit 1; }
jq -e 'select(.event == "precommit_review_passed" and .data.review_context.mode == "expanded" and .data.review_context.payload.estimated_tokens > 0)' "$event_log" >/dev/null

printf 'PASS: review budget policy and precommit fallback\n'
