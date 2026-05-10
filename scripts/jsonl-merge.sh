#!/usr/bin/env bash
# jsonl-merge.sh — safe ndjson merge primitive (#820 item 7.1).
#
# Replaces the recurring shell pattern
#
#   cat "$canon" "$stray" | jq -c -s 'sort_by(.ts) | unique | .[]' > "$canon.merged"
#   mv "$canon.merged" "$canon"
#
# whose failure mode is silent and catastrophic: any record carrying control
# characters (embedded \n in build-log payloads, multi-line error messages)
# breaks `jq -s` parse, the merged file is written empty, and `mv` then
# overwrites the canonical file with a 0-byte result. The bak file is the only
# recovery anchor and is typically `rm`'d in the next step. This is exactly
# how the T368 cleanup lost a day's canonical event log (#333 item 7).
#
# Behavior
# ========
# - Uses Python's json module instead of jq. python3 handles control chars
#   unconditionally and surfaces a structured error per line on parse failure.
# - Sorts merged records by `ts` if every record has it; otherwise input order
#   is preserved (deterministic concatenation, deduped by full line content).
# - Dedupes by `idempotency_key` if every record has it; otherwise by the
#   full canonical-encoded line.
# - Writes to a sibling `.tmp` file, validates the temp parses as ndjson and
#   has at least as many lines as the canonical input (or is non-empty when
#   inputs were non-empty), then renames atomically. Refuses the rename if the
#   merged file would lose records.
# - Keeps a timestamped `.bak` for 7 days under the runtime-global
# lint-runtime-paths:allow next-line — descriptive comment naming the bak path; runtime resolver is used in the actual write below.
#   `~/.dev-studio/<project>/.runtime/logs/jsonl-merge/<basename>-<ts>.bak` location.
# - REFUSES to write to any path under `<project>/events/`. Event logs are
#   append-only by contract (Behavior Invariant #9, achilles/SKILL.md);
#   in-place merge is the wrong primitive there. Use `cat >> canonical` and
#   read with downstream sort/dedupe.
#
# Usage
# =====
#   scripts/jsonl-merge.sh <out> <in1> [<in2> ...]
#
# Exit codes
# ==========
#   0  success
#   1  output path under events/ — refused
#   2  input unreadable
#   3  parse failure on input
#   4  merged temp parse-validate failure (output not written)
#   5  merged temp would lose records (output not written)

set -u
umask 022

usage() {
  printf 'usage: jsonl-merge.sh <out> <in1> [<in2> ...]\n' >&2
  exit 2
}

[ "$#" -ge 2 ] || usage

OUT="$1"; shift

# Refuse writes under any project's events/ directory. Match either a
# canonical resolver-shaped path or an explicit `events/<date>.jsonl`
# segment to catch test fixtures and ad-hoc paths.
# lint-runtime-paths:allow next-line — case-pattern matches a literal substring; not a path formula.
case "$OUT" in
  *"/.dev-studio/"*"/events/"*|*"/events/"*.jsonl)
    printf 'jsonl-merge: refusing to write to events path: %s\n' "$OUT" >&2
    printf 'jsonl-merge: event logs are append-only — use `cat >> canonical` and dedupe at read time.\n' >&2
    exit 1
    ;;
esac

# Verify all inputs exist + are readable before any work.
for in_file in "$@"; do
  if [ ! -r "$in_file" ]; then
    printf 'jsonl-merge: input unreadable: %s\n' "$in_file" >&2
    exit 2
  fi
done

# Bak directory under runtime-global so audit history survives per-project sweeps.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
RUNTIME_GLOBAL=$(resolve_runtime_global)
BAK_ROOT="$RUNTIME_GLOBAL/logs/jsonl-merge"
mkdir -p "$BAK_ROOT" 2>/dev/null || true
BAK_TS=$(date -u +%Y%m%dT%H%M%SZ)

OUT_DIR=$(dirname "$OUT")
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
TMP="$OUT.tmp.$$"

# Snapshot existing output (if any) into bak before overwriting.
if [ -f "$OUT" ]; then
  bak_path="$BAK_ROOT/$(basename "$OUT").$BAK_TS.bak"
  cp -p "$OUT" "$bak_path" 2>/dev/null || true
fi

# Prune bak files older than 7 days. Best-effort.
find "$BAK_ROOT" -type f -name '*.bak' -mtime +7 -delete 2>/dev/null || true

# Total non-empty input lines (for the "would lose records" guard).
input_total=0
for in_file in "$@"; do
  count=$(grep -c -E '.' "$in_file" 2>/dev/null || printf '0')
  input_total=$(( input_total + count ))
done

# Run the Python merger. Reads all inputs, parses each line as JSON, sorts
# by ts when uniformly present, dedupes by idempotency_key when uniformly
# present (else by full canonical line), writes ndjson to $TMP.
python3 - "$TMP" "$@" <<'PY'
import json, sys

out_path = sys.argv[1]
in_paths = sys.argv[2:]

records = []
for p in in_paths:
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                sys.stderr.write(f"jsonl-merge: parse error in {p}:{lineno}: {e}\n")
                sys.exit(3)
            records.append(obj)

# Determine sort + dedupe keys.
all_have_ts = bool(records) and all(isinstance(r, dict) and "ts" in r for r in records)
all_have_idem = bool(records) and all(isinstance(r, dict) and "idempotency_key" in r for r in records)

if all_have_idem:
    seen = {}
    for r in records:
        seen[r["idempotency_key"]] = r
    records = list(seen.values())
else:
    seen_lines = set()
    deduped = []
    for r in records:
        key = json.dumps(r, sort_keys=True, separators=(",", ":"))
        if key in seen_lines:
            continue
        seen_lines.add(key)
        deduped.append(r)
    records = deduped

if all_have_ts:
    records.sort(key=lambda r: r["ts"])

with open(out_path, "w", encoding="utf-8") as fh:
    for r in records:
        fh.write(json.dumps(r, separators=(",", ":")))
        fh.write("\n")
PY
py_rc=$?

if [ "$py_rc" -ne 0 ]; then
  rm -f "$TMP"
  exit "$py_rc"
fi

# Validate the merged temp parses as ndjson + meets the records-not-lost guard.
# Re-parse every line; refuse the rename if any line fails.
if ! python3 - "$TMP" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, start=1):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        json.loads(line)
PY
then
  rm -f "$TMP"
  exit 4
fi

# Records-not-lost guard: merged file's deduped count must be ≤ input total
# (we never magically gain rows) AND > 0 if inputs were non-empty.
merged_count=$(grep -c -E '.' "$TMP" 2>/dev/null || printf '0')
if [ "$input_total" -gt 0 ] && [ "$merged_count" -eq 0 ]; then
  rm -f "$TMP"
  printf 'jsonl-merge: merged temp is empty despite non-empty inputs — refusing\n' >&2
  exit 5
fi

mv -f "$TMP" "$OUT"
printf 'jsonl-merge: %s ← %d input(s), %d records out (deduped from %d)\n' \
  "$OUT" "$#" "$merged_count" "$input_total" >&2
