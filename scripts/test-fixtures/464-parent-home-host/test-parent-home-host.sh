#!/usr/bin/env bash
# Verifies parent-side GitHub calls use the login HOME from synthetic Codex homes.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t parent-home-host.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/personal"
CONTEXT_GITHUB_HOME="$TMPROOT/context-gh-home"
mkdir -p "$BIN" "$LOGIN_HOME" "$SYNTH_HOME" "$CONTEXT_GITHUB_HOME"

cat > "$BIN/dscl" <<SH
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$LOGIN_HOME"
SH
chmod +x "$BIN/dscl"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$HOME" >> "${GH_HOME_LOG:?}"
case "$1 $2" in
  "auth status") exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

GH_HOME_LOG="$TMPROOT/gh-home.log"
export GH_HOME_LOG

out="$TMPROOT/out"
err="$TMPROOT/err"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" bash -c "
  . '$ROOT/scripts/lib-paths.sh'
  resolve_current_studio_host
  with_login_home_for_github gh auth status
" >"$out" 2>"$err"

grep -qx 'codex' "$out"
grep -qx "$LOGIN_HOME" "$GH_HOME_LOG"
grep -q 'studio: HOME normalized for GitHub op (parent=codex)' "$err"

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" "$ROOT/scripts/studio-gh.sh" auth status \
  >"$TMPROOT/studio-gh.out" 2>"$TMPROOT/studio-gh.err"

grep -qx "$LOGIN_HOME" "$GH_HOME_LOG"
grep -q 'studio: HOME normalized for GitHub op (parent=codex)' "$TMPROOT/studio-gh.err"

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_GITHUB_HOME="$CONTEXT_GITHUB_HOME" \
  "$ROOT/scripts/studio-gh.sh" auth status \
  >"$TMPROOT/studio-gh-context.out" 2>"$TMPROOT/studio-gh-context.err"

grep -qx "$CONTEXT_GITHUB_HOME" "$GH_HOME_LOG"
grep -q 'studio: HOME normalized for GitHub op (parent=codex)' "$TMPROOT/studio-gh-context.err"

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_BYPASS_PARENT_HOME_FLIP=1 \
  "$ROOT/scripts/studio-gh.sh" auth status \
  >"$TMPROOT/studio-gh-bypass.out" 2>"$TMPROOT/studio-gh-bypass.err"

grep -qx "$SYNTH_HOME" "$GH_HOME_LOG"
grep -q 'STUDIO_BYPASS_PARENT_HOME_FLIP active' "$TMPROOT/studio-gh-bypass.err"
if grep -q 'HOME normalized' "$TMPROOT/studio-gh-bypass.err"; then
  printf 'studio-gh bypass still emitted HOME normalization log\n' >&2
  exit 1
fi

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_BYPASS_PARENT_HOME_FLIP=1 bash -c "
  . '$ROOT/scripts/lib-paths.sh'
  with_login_home_for_github gh auth status
" >"$TMPROOT/bypass.out" 2>"$TMPROOT/bypass.err"

grep -qx "$SYNTH_HOME" "$GH_HOME_LOG"
if grep -q 'HOME normalized' "$TMPROOT/bypass.err"; then
  printf 'bypass still emitted HOME normalization log\n' >&2
  exit 1
fi

mkdir -p "$SYNTH_HOME/.dev-studio/generic-dev-studio/state"
cat > "$SYNTH_HOME/.dev-studio/generic-dev-studio/state/env.sh" <<'SH'
STUDIO_BYPASS_PARENT_HOME_FLIP=1
SH

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" ACHILLES_PROJECT=generic-dev-studio bash -c "
  . '$ROOT/scripts/lib-paths.sh'
  with_login_home_for_github gh auth status
" >"$TMPROOT/project-env.out" 2>"$TMPROOT/project-env.err"

grep -qx "$SYNTH_HOME" "$GH_HOME_LOG"
if grep -q 'HOME normalized' "$TMPROOT/project-env.err"; then
  printf 'project env bypass still emitted HOME normalization log\n' >&2
  exit 1
fi

if command -v zsh >/dev/null 2>&1; then
  PATH="$BIN:$PATH" HOME="$SYNTH_HOME" zsh -c ". '$ROOT/scripts/lib-paths.sh'; resolve_current_studio_host" >"$TMPROOT/zsh.out"
  grep -qx 'codex' "$TMPROOT/zsh.out"
fi

printf 'PASS: parent HOME normalization and host inference\n'
