#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t swift-canonical-root-372.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

HOME_DIR="$TMPROOT/home"
WORKTREE="$TMPROOT/repo"
BIN="$TMPROOT/bin"
mkdir -p "$HOME_DIR" "$WORKTREE/Packages/Foo/Sources/Foo" "$BIN"

cat > "$BIN/swift" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "test --package-path .")
    printf 'root package invoked\n'
    exit 0
    ;;
  *)
    printf 'wrong package invocation: %s\n' "$*" >&2
    exit 3
    ;;
esac
SH
chmod +x "$BIN/swift"

(
  cd "$WORKTREE"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  cat > Package.swift <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Root",
  dependencies: [
    .package(path: "Packages/Foo")
  ],
  targets: [.target(name: "Root")]
)
SWIFT
  cat > Packages/Foo/Package.swift <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Foo", targets: [.target(name: "Foo")])
SWIFT
  printf 'public struct Foo {}\n' > Packages/Foo/Sources/Foo/Foo.swift
  git add .
  git commit -q -m initial
)

PATH="$BIN:$PATH" HOME="$HOME_DIR" ACHILLES_PROJECT=swift-canonical-root \
  "$ROOT/scripts/swift-test-gate.sh" T372 "$WORKTREE" "Packages/Foo/Sources/Foo/Foo.swift" \
  >"$TMPROOT/out" 2>"$TMPROOT/err"

event_log=$(find "$HOME_DIR/.dev-studio/swift-canonical-root/events" -name '*.jsonl' -print | head -1)
[ -n "$event_log" ] || { printf 'FAIL: no event log emitted\n' >&2; exit 1; }

jq -e '
  select(.event == "build_check_passed" and .task == "T372")
  | select(.data.mode == "swift-test")
  | select(.data.package == ".")
' "$event_log" >/dev/null || {
  printf 'FAIL: swift-test did not use canonical root package\n' >&2
  cat "$event_log" >&2
  cat "$TMPROOT/err" >&2
  exit 1
}

printf 'PASS: swift-test uses canonical root package for nested local package graph\n'
