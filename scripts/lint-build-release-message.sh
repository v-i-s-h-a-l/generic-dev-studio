#!/usr/bin/env bash
# lint-build-release-message.sh - validate Studio build/release message drafts.

set -euo pipefail
umask 022

INPUT_FILE=""
READ_STDIN=0
CHANNEL=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/lint-build-release-message.sh --file <path> --channel testflight|appstore
  scripts/lint-build-release-message.sh --stdin --channel testflight|appstore

Exit codes:
  0  message passes
  1  lint findings
  2  invocation or input error
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file) INPUT_FILE="${2:?--file requires a path}"; shift 2 ;;
    --file=*) INPUT_FILE="${1#--file=}"; shift ;;
    --stdin) READ_STDIN=1; shift ;;
    --channel) CHANNEL="${2:?--channel requires testflight|appstore}"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    -h|--help) usage ;;
    *) printf 'lint-build-release-message: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

case "$CHANNEL" in
  testflight|appstore) ;;
  *) printf 'lint-build-release-message: --channel must be testflight or appstore\n' >&2; exit 2 ;;
esac
if { [ -n "$INPUT_FILE" ] && [ "$READ_STDIN" -eq 1 ]; } || { [ -z "$INPUT_FILE" ] && [ "$READ_STDIN" -eq 0 ]; }; then
  printf 'lint-build-release-message: choose exactly one of --file or --stdin\n' >&2
  exit 2
fi
if [ -n "$INPUT_FILE" ] && [ ! -r "$INPUT_FILE" ]; then
  printf 'lint-build-release-message: unreadable input: %s\n' "$INPUT_FILE" >&2
  exit 2
fi

tmp=$(mktemp -t build-release-message.XXXXXX)
findings=$(mktemp -t build-release-message-findings.XXXXXX)
trap 'rm -f "$tmp" "$findings"' EXIT

if [ "$READ_STDIN" -eq 1 ]; then
  cat > "$tmp"
else
  cp "$INPUT_FILE" "$tmp"
fi

first_nonempty=$(awk 'NF {print; exit}' "$tmp")
case "$CHANNEL" in
  testflight)
    printf '%s\n' "$first_nonempty" | grep -Eq '^\[iOS\] build [0-9]+ is available on TestFlight$' || {
      printf 'headline: expected `[iOS] build <number> is available on TestFlight`\n' >> "$findings"
    }
    ;;
  appstore)
    printf '%s\n' "$first_nonempty" | grep -Eq '^\[iOS\] v[^[:space:]]+ [(]build [0-9]+[)] has been submitted for App Store review$' || {
      printf 'headline: expected `[iOS] v<version> (build <number>) has been submitted for App Store review`\n' >> "$findings"
    }
    ;;
esac

awk '
  function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
  }
  function normalize_bullet(s) {
    sub(/^[[:space:]]*(-|•)[[:space:]]+/, "", s)
    s = tolower(trim(s))
    gsub(/[[:space:]]+/, " ", s)
    gsub(/[[:punct:]]+$/, "", s)
    return s
  }
  /^\*(New|Fixed|Crash fixes)\*$/ {
    section_count += 1
    if (heading_seen[$0]++) {
      printf "duplicate-heading: %s\n", $0
    }
    next
  }
  /^[[:space:]]*(-|•)[[:space:]]+/ {
    if (section_count == 0) {
      printf "shape: bullet appears before any recognized section\n"
    }
    bullet = normalize_bullet($0)
    if (bullet != "" && bullet_seen[bullet]++) {
      printf "duplicate-bullet: %s\n", bullet
    }
    next
  }
  END {
    if (section_count == 0) {
      printf "shape: expected at least one section heading: *New*, *Fixed*, or *Crash fixes*\n"
    }
  }
' "$tmp" >> "$findings"

if [ -s "$findings" ]; then
  cat "$findings" >&2
  exit 1
fi

exit 0
