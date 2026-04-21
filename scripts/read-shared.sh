#!/usr/bin/env bash
# read-shared.sh — enumerate every partition under
# ~/.dev-studio/<project>/shared/<machine-id>/, merge contents of a logical
# path per the multi-machine-sync contract, and stream to stdout.
#
# Merge semantics (_shared/patterns/multi-machine-sync.md §Rules):
#   * Union across partitions (no overlap by construction).
#   * Stable total order by (occurred_at, machine-id). For files that do not
#     carry an `occurred_at` the file mtime is the stand-in; for directories
#     enumerated entries are sorted lexicographically, then per-partition.
#
# Usage:
#   scripts/read-shared.sh <logical-path>       # logical-path is a file or dir
#   scripts/read-shared.sh --list <logical-path>  # list contributing paths, don't read

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

LOGICAL="${1:?usage: read-shared.sh [--list] <logical-path>}"

case "$LOGICAL" in
  /*|*..*)
    printf 'read-shared: invalid logical path: %s\n' "$LOGICAL" >&2
    exit 2
    ;;
esac

if [ -n "${DEV_STUDIO_SHARED_ROOT:-}" ]; then
  SHARED_ROOT="$DEV_STUDIO_SHARED_ROOT"
else
  project_root=$(resolve_project_root 2>/dev/null) || {
    printf 'read-shared: cannot resolve project root\n' >&2
    exit 1
  }
  SHARED_ROOT="$project_root/shared"
fi

[ -d "$SHARED_ROOT" ] || exit 0

# Enumerate partitions.
partitions=$(find "$SHARED_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# Portable mtime (epoch seconds).
mtime_secs() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Collect every contributing path + its sort key + its partition.
# Produce lines: <sort-key>\t<partition-basename>\t<path>
# For JSONL files (one JSON per line) the sort key is per-line `occurred_at`,
# so emit one record per line. For other file types the sort key is file mtime
# and one record per file.
tmp=$(mktemp)
while IFS= read -r partition; do
  [ -z "$partition" ] && continue
  pbase=$(basename "$partition")
  target="$partition/$LOGICAL"
  if [ -d "$target" ]; then
    # Directory logical path: enumerate files inside.
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
      mt=$(mtime_secs "$f")
      printf '%s\t%s\t%s\n' "$mt" "$pbase" "$f" >> "$tmp"
    done < <(find "$target" -type f 2>/dev/null | sort)
  elif [ -f "$target" ]; then
    case "$target" in
      *.jsonl)
        # Per-line ordering — parse occurred_at / ts if present.
        awk -v p="$pbase" -v path="$target" '
          {
            key = ""
            if (match($0, /"occurred_at":"[^"]+"/)) {
              key = substr($0, RSTART+16, RLENGTH-17)
            } else if (match($0, /"ts":"[^"]+"/)) {
              key = substr($0, RSTART+6, RLENGTH-7)
            } else {
              key = "0000-00-00T00:00:00Z"
            }
            printf "%s\t%s\t%s\t%s\n", key, p, path, $0
          }
        ' "$target" >> "$tmp"
        ;;
      *)
        mt=$(mtime_secs "$target")
        printf '%s\t%s\t%s\n' "$mt" "$pbase" "$target" >> "$tmp"
        ;;
    esac
  fi
done <<< "$partitions"

# Sort by sort-key then partition. For JSONL the first column is an ISO-8601
# string and sorts lexicographically; for file-mode it's an epoch integer.
# Either way, a straight `sort` gives the contract's required order.
sort -t$'\t' -k1,1 -k2,2 "$tmp" > "$tmp.sorted"

if [ "$LIST_ONLY" -eq 1 ]; then
  awk -F'\t' '{ print $3 }' "$tmp.sorted" | sort -u
else
  awk -F'\t' 'NF >= 4 { $1=""; $2=""; $3=""; sub(/^\t\t\t/,""); print; next }
              NF == 3 { while ((getline line < $3) > 0) print line; close($3) }' \
    "$tmp.sorted"
fi

rm -f "$tmp" "$tmp.sorted"
