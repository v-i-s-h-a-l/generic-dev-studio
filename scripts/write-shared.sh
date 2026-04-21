#!/usr/bin/env bash
# write-shared.sh — write a logical path into the self-partition of tier-3
# shared state. Partition layout:
#   ~/.dev-studio/<project>/shared/<machine-id>/<logical-path>
#
# Append-or-atomic-rename per _shared/patterns/multi-machine-sync.md §Rules.
# Never touches another machine's partition.
#
# Usage:
#   scripts/write-shared.sh <logical-path> <content>       # write full file (atomic rename)
#   scripts/write-shared.sh --append <logical-path> <line> # append-only (POSIX atomic)
#   cat x | scripts/write-shared.sh <logical-path> -       # stdin → file

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

APPEND=0
if [ "${1:-}" = "--append" ]; then
  APPEND=1
  shift
fi

LOGICAL="${1:?usage: write-shared.sh [--append] <logical-path> <content-or->}"
CONTENT="${2:?usage: write-shared.sh [--append] <logical-path> <content-or->}"

# Stdin form: -
if [ "$CONTENT" = "-" ]; then
  CONTENT=$(cat)
fi

# Guard against traversal + absolute paths. The logical path must be a simple
# relative path within the self-partition (no `..`, no leading `/`).
case "$LOGICAL" in
  /*|*..*)
    printf 'write-shared: invalid logical path: %s\n' "$LOGICAL" >&2
    exit 2
    ;;
esac

# Resolve project root + partition. DEV_STUDIO_SHARED_ROOT is a test-only
# override — keeps unit fixtures out of the user's real tree.
if [ -n "${DEV_STUDIO_SHARED_ROOT:-}" ]; then
  SHARED_ROOT="$DEV_STUDIO_SHARED_ROOT"
else
  project_root=$(resolve_project_root 2>/dev/null) || {
    printf 'write-shared: cannot resolve project root — run inside a git repo or set ACHILLES_PROJECT\n' >&2
    exit 1
  }
  SHARED_ROOT="$project_root/shared"
fi

MACHINE_ID=$("$SCRIPT_DIR/machine-id.sh") || {
  printf 'write-shared: machine-id.sh failed\n' >&2
  exit 1
}

partition="$SHARED_ROOT/$MACHINE_ID"
target="$partition/$LOGICAL"

mkdir -p "$(dirname "$target")"

if [ "$APPEND" -eq 1 ]; then
  # POSIX atomic append — the caller is responsible for line-level atomicity
  # (≤ PIPE_BUF bytes per append; cf. _shared/contracts/events.md).
  printf '%s\n' "$CONTENT" >> "$target"
else
  # Atomic rename semantics: write to a tmp, rename into place. Readers see
  # either the old content or the new content, never a half-written file.
  tmp=$(mktemp "$(dirname "$target")/.$(basename "$LOGICAL").XXXXXX")
  printf '%s' "$CONTENT" > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
fi

# Echo the absolute target path so callers can confirm + tag events with it.
printf '%s\n' "$target"
