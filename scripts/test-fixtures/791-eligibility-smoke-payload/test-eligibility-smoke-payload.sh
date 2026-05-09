#!/usr/bin/env bash
# Verifies pr-reviewer-eligibility.sh materializes its smoke payload under the
# durable Studio runtime root rather than macOS $TMPDIR (#791). Sandboxed
# reviewer profiles cannot read /var/folders/.../T/ paths, so the payload root
# must come from the Studio context.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t eligibility-smoke-payload.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
REPO="$TMPROOT/chain-worktree"
DURABLE_HOME="$TMPROOT/durable-home"
STUDIO_ROOT="$DURABLE_HOME/.dev-studio"
EXPECTED_PAYLOAD_PARENT="$STUDIO_ROOT/generic-dev-studio/.runtime/reviewer-payloads/eligibility-smoke"
PAYLOAD_PATH_RECORD="$TMPROOT/payload-path.txt"
mkdir -p "$BIN" "$REPO/.studio" "$DURABLE_HOME" "$TMPROOT/session-tmp"

cat > "$REPO/.studio/chain-task-start.json" <<'JSON'
{
  "source_issue": {
    "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/791"
  }
}
JSON

# Stub claude: assert the smoke payload lives under the durable runtime root,
# then print the verdict the script expects.
expected_payload_parent_q=$(printf '%q' "$EXPECTED_PAYLOAD_PARENT")
payload_path_record_q=$(printf '%q' "$PAYLOAD_PATH_RECORD")
{
printf '#!/usr/bin/env bash\n'
printf 'EXPECTED_PAYLOAD_PARENT=%s\n' "$expected_payload_parent_q"
printf 'PAYLOAD_PATH_RECORD=%s\n' "$payload_path_record_q"
cat <<'SH'
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || {
  printf 'stub claude: missing or unreadable REVIEW_PAYLOAD: %s\n' "${REVIEW_PAYLOAD:-<unset>}" >&2
  exit 3
}
case "$REVIEW_PAYLOAD" in
  "$EXPECTED_PAYLOAD_PARENT"/run.*/payload.md) ;;
  *)
    printf 'stub claude: payload not under durable runtime root: %s\n' "$REVIEW_PAYLOAD" >&2
    printf 'stub claude: expected %s/run.*/payload.md\n' "$EXPECTED_PAYLOAD_PARENT" >&2
    exit 4
    ;;
esac
case "$REVIEW_PAYLOAD" in
  */pr-reviewer-smoke.*/payload.md)
    printf 'stub claude: payload uses pre-fix mktemp path: %s\n' "$REVIEW_PAYLOAD" >&2
    exit 5
    ;;
esac
printf '%s\n' "$REVIEW_PAYLOAD" > "$PAYLOAD_PATH_RECORD"
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
} > "$BIN/claude"
chmod +x "$BIN/claude"

# Real yq is required by lib-paths.sh helpers; keep it on PATH.
command -v yq >/dev/null 2>&1 || {
  printf 'SKIP: yq not on PATH; pr-reviewer-eligibility requires it\n' >&2
  exit 0
}

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export TMPDIR="$TMPROOT/session-tmp"
export STUDIO_CONTEXT_STUDIO_HOME="$STUDIO_ROOT"
export STUDIO_CONTEXT_REPO_ROOT="$REPO"
export STUDIO_CONTEXT_PROJECT_SLUG="generic-dev-studio"
export STUDIO_REVIEWER_SMOKE_TIMEOUT_SEC=0
mkdir -p "$HOME"

out="$TMPROOT/out.txt"
err="$TMPROOT/err.txt"
if ! (cd "$REPO" && bash "$ROOT/scripts/pr-reviewer-eligibility.sh" claude-reviewer >"$out" 2>"$err"); then
  printf 'FAIL: pr-reviewer-eligibility rejected the durable payload handoff\n' >&2
  printf '%s\n' '--- stdout ---' >&2
  sed -n '1,80p' "$out" >&2 || true
  printf '%s\n' '--- stderr ---' >&2
  sed -n '1,120p' "$err" >&2 || true
  exit 1
fi

grep -q '^PR_REVIEWER_ELIGIBLE=1' "$out" || {
  printf 'FAIL: eligibility did not report PR_REVIEWER_ELIGIBLE=1\n' >&2
  sed -n '1,40p' "$out" >&2 || true
  exit 1
}

[ -s "$PAYLOAD_PATH_RECORD" ] || {
  printf 'FAIL: stub claude did not observe a payload path\n' >&2
  exit 1
}

# Confirm the recorded path is under the durable runtime root and not under
# macOS $TMPDIR — the regression class fixed for #634 / commit 54bfa3e.
recorded=$(head -1 "$PAYLOAD_PATH_RECORD")
case "$recorded" in
  "$EXPECTED_PAYLOAD_PARENT"/run.*/payload.md) ;;
  *)
    printf 'FAIL: recorded payload not under durable runtime root: %s\n' "$recorded" >&2
    exit 1
    ;;
esac
case "$recorded" in
  */pr-reviewer-smoke.*/payload.md)
    printf 'FAIL: payload uses pre-fix mktemp path: %s\n' "$recorded" >&2
    exit 1
    ;;
esac

# Verify cleanup happened by default (no STUDIO_KEEP_REVIEWER_SMOKE_PAYLOADS).
[ -e "$recorded" ] && {
  printf 'FAIL: smoke payload not cleaned up after success: %s\n' "$recorded" >&2
  exit 1
}

# Verify keep-payloads escape hatch retains the directory.
keep_record="$TMPROOT/keep-payload-path.txt"
sed -i.bak "s|$PAYLOAD_PATH_RECORD|$keep_record|" "$BIN/claude"
rm -f "$BIN/claude.bak"
STUDIO_KEEP_REVIEWER_SMOKE_PAYLOADS=1 \
  bash -c "cd \"$REPO\" && bash \"$ROOT/scripts/pr-reviewer-eligibility.sh\" claude-reviewer" \
  >"$TMPROOT/keep-out.txt" 2>"$TMPROOT/keep-err.txt" || {
    printf 'FAIL: keep-payloads run did not pass eligibility\n' >&2
    sed -n '1,80p' "$TMPROOT/keep-err.txt" >&2 || true
    exit 1
  }
keep_path=$(head -1 "$keep_record" 2>/dev/null || true)
[ -n "$keep_path" ] && [ -e "$keep_path" ] || {
  printf 'FAIL: STUDIO_KEEP_REVIEWER_SMOKE_PAYLOADS=1 did not retain payload: %s\n' "$keep_path" >&2
  exit 1
}

printf 'PASS: pr-reviewer-eligibility smoke payload uses durable Studio runtime root\n'
