#!/usr/bin/env bash
# Verifies the default pre-commit hook stays deterministic and records duration.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t fast-precommit-hook.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

REPO="$TMPROOT/repo"
mkdir -p "$REPO/scripts"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" remote add origin git@example.com:owner/generic-dev-studio.git

cp "$ROOT/.githooks/pre-commit" "$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"

cat > "$REPO/scripts/update-surface-manifest.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$REPO/scripts/capability-manifest.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$REPO/scripts/pre-commit-review.sh" <<'SH'
#!/usr/bin/env bash
printf 'pre-commit-review should not run in the default hook path\n' >&2
exit 9
SH
cat > "$REPO/scripts/lib-ledger.sh" <<'SH'
#!/usr/bin/env bash
_json_escape() { printf '%s' "$1"; }
emit_event_keyed() {
  printf '%s %s\n' "$3" "$5" >> "$EVENT_LOG"
}
SH
chmod +x "$REPO/scripts/update-surface-manifest.sh" "$REPO/scripts/capability-manifest.sh" "$REPO/scripts/pre-commit-review.sh"

export EVENT_LOG="$TMPROOT/events.log"
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt

if ! (cd "$REPO" && ARCH_LINT=0 git commit -qm initial >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  printf 'FAIL: deterministic pre-commit hook rejected commit\n' >&2
  sed -n '1,120p' "$TMPROOT/err" >&2 || true
  exit 1
fi

if grep -q 'pre-commit-review should not run' "$TMPROOT/err"; then
  printf 'FAIL: hook invoked manual LLM reviewer\n' >&2
  exit 1
fi
if ! grep -q 'precommit_hook_completed' "$EVENT_LOG"; then
  printf 'FAIL: hook duration event was not emitted\n' >&2
  cat "$EVENT_LOG" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -q '"duration_s":' "$EVENT_LOG"; then
  printf 'FAIL: hook duration event did not include duration_s\n' >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

printf 'PASS: fast pre-commit hook is deterministic and timed\n'
