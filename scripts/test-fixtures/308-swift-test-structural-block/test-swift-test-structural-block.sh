#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMPROOT=$(mktemp -d -t swift-test-structural-block.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

HOME_DIR="$TMPROOT/home"
WORKTREE="$TMPROOT/repo"
BIN="$TMPROOT/bin"
mkdir -p "$HOME_DIR" "$WORKTREE/Sources/Foo" "$BIN"

cat > "$BIN/swift" <<'SH'
#!/usr/bin/env bash
printf "error: invalid manifest at Package.swift\n" >&2
printf "error: resource 'Fixtures' not found\n" >&2
exit 1
SH
chmod +x "$BIN/swift"

(
  cd "$WORKTREE"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "Foo", targets: [.target(name: "Foo")])\n' > Package.swift
  printf 'public struct Foo {}\n' > Sources/Foo/Foo.swift
  git add .
  git commit -q -m initial
)

set +e
PATH="$BIN:$PATH" HOME="$HOME_DIR" ACHILLES_PROJECT=swift-test-structural-block \
  "$ROOT/scripts/swift-test-gate.sh" T308 "$WORKTREE" "Sources/Foo/Foo.swift" \
  >"$TMPROOT/out" 2>"$TMPROOT/err"
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  printf 'FAIL: expected swift-test-gate rc=2, got %s\n' "$rc" >&2
  cat "$TMPROOT/out" >&2
  cat "$TMPROOT/err" >&2
  exit 1
fi

event_log=$(find "$HOME_DIR/.dev-studio/swift-test-structural-block/events" -name '*.jsonl' -print | head -1)
if [ -z "$event_log" ]; then
  printf 'FAIL: no event log emitted\n' >&2
  exit 1
fi

jq -e '
  select(.event == "build_check_failed" and .task == "T308")
  | select(.data.mode == "swift-test")
  | select(.data.reason == "focused_verification_structurally_blocked")
  | select(.data.verification_blocked == true)
  | select(.data.verdict_note == "focused verification structurally blocked")
' "$event_log" >/dev/null || {
  printf 'FAIL: structural blocker event missing\n' >&2
  cat "$event_log" >&2
  exit 1
}

printf 'PASS: swift-test structural blocker classified\n'
