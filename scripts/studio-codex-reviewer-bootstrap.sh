#!/usr/bin/env bash
# studio-codex-reviewer-bootstrap.sh — seed an isolated codex auth home for
# the codex-reviewer profile.
#
# Background: PR #829 traded reviewer isolation for working cross-host review
# under codex ChatGPT-OAuth (which 401s when HOME or CODEX_HOME is overridden
# against an un-seeded `.codex/`). When `~/.codex-reviewer/` exists with its
# own auth state, `scripts/lib-studio-context.sh` resolves codex-reviewer's
# auth_home to it and the eligibility/phase-review wrappers take the
# full-isolation branch (HOME=tmpdir, CODEX_HOME=~/.codex-reviewer). This
# script creates that directory and walks the user through a one-time
# `codex login` to populate it.
#
# Why this needs a human step: codex 0.130+ ChatGPT-OAuth state is not
# file-copyable from `~/.codex/` — see issue #866 for the experimental
# findings. The only known path to seeded reviewer auth is a fresh
# `codex login` performed under the isolated CODEX_HOME.
#
# Usage:
#   scripts/studio-codex-reviewer-bootstrap.sh           # interactive
#   scripts/studio-codex-reviewer-bootstrap.sh --verify  # only re-run the smoke
#   scripts/studio-codex-reviewer-bootstrap.sh --force   # re-seed even if dir exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"

mode="bootstrap"
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) mode="verify" ;;
    --force) force=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

login_home="$(_studio_context_login_home)" || {
  echo "fatal: could not resolve login HOME" >&2
  exit 1
}
reviewer_home="$login_home/.codex-reviewer"

if ! command -v codex >/dev/null 2>&1; then
  echo "fatal: codex CLI not on PATH; install from https://github.com/openai/codex" >&2
  exit 1
fi

run_smoke() {
  echo "→ Running reviewer eligibility smoke (codex-reviewer)..."
  if "$SCRIPT_DIR/pr-reviewer-eligibility.sh" codex-reviewer; then
    echo "✓ codex-reviewer eligible — isolation working."
    return 0
  fi
  echo "✗ smoke failed. The isolated CODEX_HOME exists but auth did not survive." >&2
  echo "  Common causes:" >&2
  echo "    - codex login completed but stored credentials in the user keychain" >&2
  echo "      rather than under \$CODEX_HOME. This is the failure mode documented" >&2
  echo "      in issue #866; remediation requires a separate OpenAI account in a" >&2
  echo "      fresh browser session." >&2
  echo "    - You ran 'codex login' without CODEX_HOME pointing at $reviewer_home." >&2
  return 1
}

if [ "$mode" = "verify" ]; then
  [ -d "$reviewer_home" ] || { echo "no $reviewer_home; run without --verify first" >&2; exit 1; }
  run_smoke
  exit $?
fi

if [ -d "$reviewer_home" ] && [ "$force" -eq 0 ]; then
  echo "→ $reviewer_home already exists. Verifying instead of re-seeding."
  echo "  (use --force to wipe and re-seed)"
  run_smoke
  exit $?
fi

if [ "$force" -eq 1 ] && [ -d "$reviewer_home" ]; then
  echo "→ --force: removing existing $reviewer_home"
  rm -rf "$reviewer_home"
fi

mkdir -p "$reviewer_home"
chmod 700 "$reviewer_home"
echo "✓ Created $reviewer_home (mode 700)"
echo
echo "Next: log in to codex under the isolated CODEX_HOME."
echo
echo "  In a NEW terminal (or after exiting this one), run:"
echo
echo "    CODEX_HOME=$reviewer_home codex login"
echo
echo "  Follow the browser prompt. For real isolation from your primary codex"
echo "  identity, sign in with a SEPARATE OpenAI account (fresh browser profile"
echo "  or private window). Same-account concurrent sessions may or may not be"
echo "  permitted by codex — try same-account first; if the smoke 401s, retry"
echo "  with a separate account."
echo
echo "When 'codex login' completes, re-run:"
echo
echo "    $0 --verify"
echo
