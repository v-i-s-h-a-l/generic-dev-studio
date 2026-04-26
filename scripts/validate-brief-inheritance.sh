#!/usr/bin/env bash
# validate-brief-inheritance.sh — silent-absorb gate (#162 trimmed slice).
#
# Asserts that every concern (`known_issues[]` + `follow_ups[]`) emitted by the
# named predecessor debriefs appears, by keyword, in the successor brief's
# body. Runs at brief-write time, before `transition_brief_state … ready`.
# Fails loud when a concern's probe term is not grep-findable in the body.
#
# Why this exists: the prior contract emitted concerns but did not enforce
# downstream resolution. Concerns were dropped between debrief and the next
# brief because the trace was mental-only. This script makes silent-absorb a
# structural impossibility for new debriefs (which carry stable ids per
# debrief@2.3.0); legacy string-form concerns participate too, with ids
# synthesized from their array index.
#
# Probe-term selection:
#   1. If `category` is set, use it (strongest signal — author opted in).
#   2. Otherwise, treat every 6+ character alphanumeric token in `text` as a
#      candidate probe; the concern is considered addressed if ANY candidate
#      matches the brief body. This is intentionally permissive for legacy
#      string concerns (no category metadata) — the floor is "the brief uses
#      *some* word from the concern," not "the brief mirrors a specific term."
#   3. Fallback when no 6+ char token exists: the full lowercased text.
#
# Usage:
#   scripts/validate-brief-inheritance.sh <brief.yaml> \
#       --predecessor <debrief.yaml> [--predecessor <debrief.yaml> ...]
#
# Exit 0: every predecessor concern has a matching probe in the brief body
#         (or no predecessor was passed — first-time brief carve-out).
# Exit 1: one or more concerns unresolved — list printed to stderr.
# Exit 2: bad invocation.
#
# Dependencies: yq (mikefarah). awk fallback NOT provided — concern shape is
# union-typed and grep-parsing yaml is a non-starter. The brief-mode gate
# already requires yq via `lib-ledger`'s helpers.

set -u
umask 022

BRIEF=""
PREDS=()
MISSES=0

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
emit_warn() { printf '%s\n' "$1" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --predecessor)
      [ $# -ge 2 ] || { echo "E_BAD_FLAG: --predecessor needs a path" >&2; exit 2; }
      PREDS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    -*) echo "E_BAD_FLAG: unknown $1" >&2; exit 2 ;;
    *) [ -z "$BRIEF" ] && BRIEF="$1" || { echo "E_BAD_ARG: $1" >&2; exit 2; }; shift ;;
  esac
done

[ -n "$BRIEF" ] || usage
[ -f "$BRIEF" ] || { echo "E_NO_BRIEF: $BRIEF not a file" >&2; exit 2; }

if [ "${#PREDS[@]}" -eq 0 ]; then
  emit_warn "W_NO_PREDECESSORS: no --predecessor passed; inheritance check skipped (this is fine for first-time briefs)"
  exit 0
fi

command -v yq >/dev/null 2>&1 || { echo "E_NO_YQ: yq required (mikefarah)" >&2; exit 2; }

# Lowercased brief body — single pass, search target.
BRIEF_HAY=$(yq -r '.body // ""' "$BRIEF" 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ -n "$BRIEF_HAY" ] || emit_warn "W_EMPTY_BODY: brief body is empty — concerns cannot be matched"

# Emit every 6+-char alphanumeric token in `$1` (lowercased), one per line.
# Empty output when nothing meets the threshold.
candidate_tokens() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 6'
}

# Stream a debrief's concerns as `<kind>\t<index>\t<id>\t<category>\t<text>`
# per line. Two passes per array (mikefarah yq has no jq-style `if-then-else`
# expression — `select` filters by tag instead).
extract_concerns() {
  local file="$1" arr kind
  # `-` is the empty-field sentinel — bash's `read` with `IFS=$'\t'` collapses
  # consecutive tabs (tab is whitespace), so genuinely-empty fields would be
  # misparsed without a placeholder. The shell side translates `-` back to ""
  # before use.
  for pair in "known_issues:ki" "follow_ups:fu"; do
    arr="${pair%:*}"; kind="${pair#*:}"
    yq -r "(.${arr} // []) | to_entries | .[] | select(.value | tag == \"!!map\") |
      [\"${kind}\", (.key + 1 | tostring), ((.value.id // \"\") | sub(\"^$\"; \"-\")),
       ((.value.category // \"\") | sub(\"^$\"; \"-\")), ((.value.text // \"\") | sub(\"^$\"; \"-\"))] | @tsv" "$file"
    yq -r "(.${arr} // []) | to_entries | .[] | select(.value | tag == \"!!str\") |
      [\"${kind}\", (.key + 1 | tostring), \"-\", \"-\", .value] | @tsv" "$file"
  done
}

# Translate the `-` sentinel back to empty.
unblank() { [ "$1" = "-" ] && printf '' || printf '%s' "$1"; }

for pred in "${PREDS[@]}"; do
  if [ ! -f "$pred" ]; then
    emit_warn "W_MISSING_PRED: $pred not a file"
    continue
  fi
  base=$(basename "$pred" .yaml)

  while IFS=$'\t' read -r kind idx id category text; do
    [ -z "$kind" ] && continue
    id=$(unblank "$id"); category=$(unblank "$category"); text=$(unblank "$text")
    [ -n "$id" ] || id="${base}-${kind}-${idx}"

    matched=0
    if [ -n "$category" ]; then
      probe=$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')
      printf '%s' "$BRIEF_HAY" | grep -qF "$probe" && matched=1
      probe_shown="$probe"
    else
      probe_shown=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
      while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        if printf '%s' "$BRIEF_HAY" | grep -qF "$tok"; then
          matched=1; probe_shown="$tok"; break
        fi
      done < <(candidate_tokens "$text")
      # Fallback: no 6+ char token at all, fall back to full text.
      if [ "$matched" -eq 0 ] && ! candidate_tokens "$text" | grep -q .; then
        printf '%s' "$BRIEF_HAY" | grep -qF "$probe_shown" && matched=1
      fi
    fi

    if [ "$matched" -eq 0 ]; then
      printf 'MISS\t%s\t%s\t%s\n' "$id" "$probe_shown" "$pred" >&2
      MISSES=$((MISSES + 1))
    fi
  done < <(extract_concerns "$pred")
done

if [ "$MISSES" -gt 0 ]; then
  printf '\nE_INHERITANCE: %d concern(s) from predecessor debrief(s) lack a grep-findable trace in %s\n' "$MISSES" "$BRIEF" >&2
  printf 'Resolution: amend the brief body to address the concern (cite the keyword), or move the concern to a separate task and pass that task as a fresh predecessor link.\n' >&2
  exit 1
fi

exit 0
