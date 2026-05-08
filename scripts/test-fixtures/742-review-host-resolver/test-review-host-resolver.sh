#!/usr/bin/env bash
# Verifies the shared review-host resolver drives multiple review surfaces with
# consistent auth-home and stdin handling.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t review-host-resolver.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac

[ -n "${CLAUDE_REVIEWER_HOME:-}" ] || { printf 'missing CLAUDE_REVIEWER_HOME\n' >&2; exit 11; }
[ "$HOME" = "$CLAUDE_REVIEWER_HOME" ] || { printf 'claude reviewer did not use reviewer auth HOME\n' >&2; exit 12; }
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || { printf 'missing CLAUDE_CONFIG_DIR\n' >&2; exit 13; }
case "${CLAUDE_CONFIG_DIR:-}" in
  */.claude-reviewer) ;;
  *) printf 'bad CLAUDE_CONFIG_DIR: %s\n' "$CLAUDE_CONFIG_DIR" >&2; exit 14 ;;
esac
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing review payload\n' >&2; exit 15; }
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 16; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 17 ;;
esac

case " $* " in
  *"Studio reviewer smoke test."*)
    printf 'claude smoke summary\n'
    printf 'STUDIO_REVIEW_VERDICT=approved\n'
    ;;
  *"BEGIN PHASE ARTIFACT"*|*"PHASE_REVIEW_VERDICT=clean"*)
    printf 'phase summary\n'
    printf 'PHASE_REVIEW_VERDICT=clean\n'
    ;;
  *)
    printf 'generic claude review summary\n'
    printf 'STUDIO_REVIEW_VERDICT=approved\n'
    ;;
esac
SH
chmod +x "$BIN/claude"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac

[ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME" ] || { printf 'missing CODEX_HOME\n' >&2; exit 21; }
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing review payload\n' >&2; exit 22; }
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 23; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 24 ;;
esac

case " $* " in
  *"Read "*", review the staged studio diff,"*)
    printf 'precommit summary\n'
    printf 'STUDIO_REVIEW_VERDICT=approved_with_fixes\n'
    ;;
  *"Studio reviewer smoke test."*)
    printf 'codex smoke summary\n'
    printf 'STUDIO_REVIEW_VERDICT=approved\n'
    ;;
  *)
    printf 'generic codex review summary\n'
    printf 'STUDIO_REVIEW_VERDICT=approved_with_fixes\n'
    ;;
esac
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"
export HOME="$TMPROOT/caller-home"
export CLAUDE_REVIEWER_HOME="$TMPROOT/claude-reviewer-home"
export CLAUDE_REVIEWER_CONFIG_DIR="$CLAUDE_REVIEWER_HOME/.claude-reviewer"
export CODEX_REVIEWER_HOME="$TMPROOT/codex-reviewer-home"
export STUDIO_PARENT_HOST="codex-code"
mkdir -p "$HOME/.config/gh" "$CLAUDE_REVIEWER_HOME" "$CLAUDE_REVIEWER_CONFIG_DIR" "$CODEX_REVIEWER_HOME"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"

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

default_codex_host=$(bash -c ". '$ROOT/scripts/lib-paths.sh'; . '$ROOT/scripts/lib-studio-context.sh'; . '$ROOT/scripts/lib-review-host.sh'; review_host_default_for_parent_host codex-code")
default_claude_host=$(bash -c ". '$ROOT/scripts/lib-paths.sh'; . '$ROOT/scripts/lib-studio-context.sh'; . '$ROOT/scripts/lib-review-host.sh'; review_host_default_for_parent_host claude-code")
assert "default host follows parent family" "[ '$default_codex_host' = 'claude-reviewer' ] && [ '$default_claude_host' = 'codex-reviewer' ]"

codex_context=$(STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer CODEX_REVIEWER_HOME="$CODEX_REVIEWER_HOME" bash -c ". '$ROOT/scripts/lib-paths.sh'; . '$ROOT/scripts/lib-studio-context.sh'; . '$ROOT/scripts/lib-review-host.sh'; review_host_resolve_context codex-reviewer delegated-host-spawn && printf '%s:%s\n' \"\$REVIEW_HOST_KIND\" \"\$REVIEW_HOST_CODEX_HOME\"")
claude_context=$(STUDIO_CONTEXT_HOST_PROFILE=claude-reviewer CLAUDE_REVIEWER_HOME="$CLAUDE_REVIEWER_HOME" CLAUDE_REVIEWER_CONFIG_DIR="$CLAUDE_REVIEWER_CONFIG_DIR" bash -c ". '$ROOT/scripts/lib-paths.sh'; . '$ROOT/scripts/lib-studio-context.sh'; . '$ROOT/scripts/lib-review-host.sh'; review_host_resolve_context claude-reviewer delegated-host-spawn && printf '%s:%s:%s\n' \"\$REVIEW_HOST_KIND\" \"\$REVIEW_HOST_AUTH_HOME\" \"\$REVIEW_HOST_CLAUDE_CONFIG_DIR\"")
assert "helper resolves codex reviewer context" "[ '$codex_context' = 'codex:$CODEX_REVIEWER_HOME' ]"
assert "helper resolves claude reviewer context" "[ '$claude_context' = 'claude:$CLAUDE_REVIEWER_HOME:$CLAUDE_REVIEWER_CONFIG_DIR' ]"

phase_input="$TMPROOT/phase.md"
phase_output="$TMPROOT/phase.review.md"
cat > "$phase_input" <<'MD'
# Phase plan

Review ask: what's still wrong?
MD
if ! bash "$ROOT/scripts/phase-review.sh" \
  --review-host claude-reviewer \
  --kind plan \
  --input "$phase_input" \
  --output "$phase_output" >"$TMPROOT/phase.out" 2>"$TMPROOT/phase.err"; then
  sed -n '1,120p' "$TMPROOT/phase.out" >&2 || true
  sed -n '1,120p' "$TMPROOT/phase.err" >&2 || true
  sed -n '1,120p' "$phase_output" >&2 || true
  sed -n '1,120p' "$phase_output.err" >&2 || true
  exit 1
fi
assert "phase review used shared resolver" "grep -q 'PHASE_REVIEW_HOST=claude-reviewer' '$TMPROOT/phase.out' && grep -q 'PHASE_REVIEW_VERDICT=clean' '$TMPROOT/phase.out' && grep -q 'phase summary' '$phase_output'"

repo="$TMPROOT/precommit-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
printf 'one\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial
printf 'two\n' >> "$repo/file.txt"
git -C "$repo" add file.txt

if ! (cd "$repo" && bash "$ROOT/scripts/pre-commit-review.sh" --review-host codex-reviewer >"$TMPROOT/precommit.out" 2>"$TMPROOT/precommit.err"); then
  sed -n '1,120p' "$TMPROOT/precommit.out" >&2 || true
  sed -n '1,120p' "$TMPROOT/precommit.err" >&2 || true
  exit 1
fi
assert "pre-commit review used shared resolver" "grep -q 'PRECOMMIT_REVIEW_HOST=codex-reviewer' '$TMPROOT/precommit.out' && grep -q 'PRECOMMIT_REVIEW_VERDICT=approved_with_fixes' '$TMPROOT/precommit.out'"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: shared review-host resolver drives multiple review surfaces\n'
