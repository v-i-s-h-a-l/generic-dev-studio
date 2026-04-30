#!/usr/bin/env bash
# Verifies staged architecture lint avoids unrelated full-repo fixture scans.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t lint-architecture-staged.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

REPO="$TMPROOT/repo"
mkdir -p "$REPO/scripts" "$REPO/_shared/schemas" "$REPO/agent/modes"
cp "$ROOT/scripts/lint-architecture.sh" "$REPO/scripts/lint-architecture.sh"
cp "$ROOT/scripts/lib-paths.sh" "$REPO/scripts/lib-paths.sh"
chmod +x "$REPO/scripts/lint-architecture.sh"

cat > "$REPO/_shared/schemas/token-budgets.json" <<'JSON'
{"mode_budgets":{}}
JSON

for i in $(seq 1 40); do
  cat > "$REPO/agent/modes/mode-$i.md" <<YAML
---
name: mode-$i
description: fixture mode $i
type: mode
snapshots: []
reads: []
writes: []
---

Mode $i body.
YAML
done

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" add .
git -C "$REPO" commit -qm initial

printf 'small change\n' > "$REPO/README.md"
git -C "$REPO" add README.md

staged_err="$TMPROOT/staged.err"
started=$(date +%s)
if ! (cd "$REPO" && scripts/lint-architecture.sh --staged >/tmp/staged.out 2>"$staged_err"); then
  printf 'FAIL: staged lint failed\n' >&2
  cat "$staged_err" >&2
  exit 1
fi
duration=$(( $(date +%s) - started ))
if [ "$duration" -gt 5 ]; then
  printf 'FAIL: staged lint took %ss, expected <=5s\n' "$duration" >&2
  exit 1
fi
if grep -q 'W_MISSING_PACK_FIXTURE' "$staged_err"; then
  printf 'FAIL: staged lint emitted unrelated fixture warnings\n' >&2
  cat "$staged_err" >&2
  exit 1
fi
grep -q 'lint-architecture: 0 errors, 0 warnings (staged)' "$staged_err" || {
  printf 'FAIL: staged lint summary missing\n' >&2
  cat "$staged_err" >&2
  exit 1
}

full_err="$TMPROOT/full.err"
(cd "$REPO" && scripts/lint-architecture.sh --full >/tmp/full.out 2>"$full_err")
grep -q 'Architecture warnings' "$full_err" || {
  printf 'FAIL: full lint warning section missing\n' >&2
  cat "$full_err" >&2
  exit 1
}
grep -q 'W_MISSING_PACK_FIXTURE' "$full_err" || {
  printf 'FAIL: full lint did not report fixture debt\n' >&2
  cat "$full_err" >&2
  exit 1
}

printf 'PASS: lint-architecture staged fast path\n'
