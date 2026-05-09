#!/usr/bin/env bash
# Verifies the staged-diff review gate accepts approved verdicts and keeps the
# reviewer environment scrubbed.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t precommit-review.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

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
  *"smoke test"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || exit 3
grep -q 'Staged diff:' "$REVIEW_PAYLOAD" || exit 7
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 5; }
[ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME" ] || { printf 'reviewer missing explicit CODEX_HOME\n' >&2; exit 6; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 4 ;;
esac
printf 'review summary\n'
printf 'STUDIO_REVIEW_VERDICT=approved_with_fixes\n'
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"
export HOME="$TMPROOT/caller-home"
export TMPDIR="$TMPROOT/session-tmp"
export STUDIO_CONTEXT_STUDIO_HOME="$TMPROOT/durable-home/.dev-studio"
export CODEX_REVIEWER_HOME="$TMPROOT/reviewer-home"
mkdir -p "$HOME/.config/gh" "$CODEX_REVIEWER_HOME" "$TMPDIR" "$(dirname "$STUDIO_CONTEXT_STUDIO_HOME")"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"

resolved_codex_home=$(STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_get auth_home delegated-host-spawn")
[ "$resolved_codex_home" = "$CODEX_REVIEWER_HOME" ] || {
  printf 'fixture resolved codex auth home incorrectly: %s\n' "$resolved_codex_home" >&2
  exit 1
}

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm initial
printf 'two\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt

out="$TMPROOT/out.txt"
err="$TMPROOT/err.txt"
if ! (cd "$REPO" && bash "$ROOT/scripts/pre-commit-review.sh" --review-host codex-reviewer >"$out" 2>"$err"); then
  printf 'FAIL: pre-commit review rejected approved_with_fixes\n' >&2
  sed -n '1,120p' "$err" >&2 || true
  exit 1
fi

grep -q 'PRECOMMIT_REVIEW_HOST=codex-reviewer' "$out" || {
  printf 'FAIL: review host not reported\n' >&2
  exit 1
}
grep -q 'PRECOMMIT_REVIEW_VERDICT=approved_with_fixes' "$out" || {
  printf 'FAIL: verdict not reported\n' >&2
  exit 1
}

printf 'PASS: pre-commit review accepts approved verdict\n'
