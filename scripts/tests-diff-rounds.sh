#!/usr/bin/env bash
# tests-diff-rounds.sh — Step 10 diff subcommand for /chanakya test-flow.
#
# Compares two rounds case-by-case and prints a markdown diff report to
# stdout. Classifies each case as same/regressed→fixed/regression-introduced/
# only-in-A/new-in-B; surfaces perf deltas when both rounds carry timing_ms.
#
# Usage:
#   scripts/tests-diff-rounds.sh <round-a> <round-b>
#
# Exit codes:
#   0  report emitted (or both rounds empty)
#   2  round not found or missing yq on YAML surface

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

RA="${1:-}"
RB="${2:-}"
if [ -z "$RA" ] || [ -z "$RB" ]; then
  printf 'usage: tests-diff-rounds.sh <round-a> <round-b>\n' >&2
  exit 2
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
ROUNDS_DIR="$PROJECT_ROOT/plans/rounds"

# Extract per-case TSV lines `<id>\t<title>\t<result>\t<timing_ms>` from a
# round. YAML preferred; legacy markdown is the Phase 2.6 fallback.
extract_cases() {
  local rn="$1"
  local yaml=""
  if command -v yq >/dev/null 2>&1 && [ -d "$ROUNDS_DIR" ]; then
    for y in "$ROUNDS_DIR"/*.yaml; do
      [ -f "$y" ] || continue
      if [ "$(yq -r '.round_number // ""' "$y" 2>/dev/null || echo "")" = "$rn" ]; then
        yaml="$y"; break
      fi
    done
  fi
  if [ -n "$yaml" ]; then
    yq -r '
      .cases // [] |
      .[] |
      (.id // "—") + "\t" + (.title // "—") + "\t" + (.result // "pending") + "\t" + ((.timing_ms // "null") | tostring)
    ' "$yaml" 2>/dev/null
    return 0
  fi

  local legacy="$PROJECT_ROOT/plans/user-testing-rounds/user-testing-round${rn}.md"
  [ -f "$legacy" ] || return 1
  # Parse `### <id> — <title>` headings followed by `Result:` + optional `Timing:`.
  awk '
    /^###[[:space:]]/ {
      line=$0
      sub(/^###[[:space:]]*/, "", line)
      n=split(line, a, "[[:space:]]*—[[:space:]]*")
      id=a[1]
      title=(n >= 2 ? a[2] : line)
      sub(/[[:space:]]*\[.*$/, "", title)
      result="pending"; timing="null"; have_res=0
      next
    }
    /^Result:/ && !have_res {
      if ($0 ~ /\[[xX]\][[:space:]]*pass/) result="pass"
      else if ($0 ~ /\[[xX]\][[:space:]]*fail/) result="fail"
      have_res=1
      next
    }
    /^Timing:/ {
      t=$0; sub(/^Timing:[[:space:]]*/, "", t); gsub(/[^0-9.]/, "", t)
      if (t != "") timing=t
      next
    }
    /^###[[:space:]]/ || /^##[[:space:]]/ {
      if (id != "") {
        printf "%s\t%s\t%s\t%s\n", id, title, result, timing
      }
    }
    END {
      if (id != "") printf "%s\t%s\t%s\t%s\n", id, title, result, timing
    }
  ' "$legacy"
}

A_TSV=$(extract_cases "$RA" 2>/dev/null || true)
B_TSV=$(extract_cases "$RB" 2>/dev/null || true)

if [ -z "$A_TSV" ] && [ -z "$B_TSV" ]; then
  printf 'error: neither round %s nor round %s carry any cases\n' "$RA" "$RB" >&2
  exit 2
fi

# Join sides by case id. Build associative arrays keyed by id.
tmp_a=$(mktemp); tmp_b=$(mktemp)
printf '%s\n' "$A_TSV" > "$tmp_a"
printf '%s\n' "$B_TSV" > "$tmp_b"

printf '## Test-Flow Diff: Round %s → Round %s\n\n' "$RA" "$RB"

regressions=$(mktemp)
fixes=$(mktemp)
only_a=$(mktemp)
only_b=$(mktemp)
same=$(mktemp)
perf=$(mktemp)

# `awk` does the matching in a single pass — load A into a map, stream B,
# emit classified lines into the category buckets.
awk -F'\t' -v reg="$regressions" -v fix="$fixes" -v oa="$only_a" \
    -v ob="$only_b" -v sm="$same" -v pf="$perf" '
  NR==FNR {
    if (NF >= 3) {
      a_title[$1]=$2; a_result[$1]=$3; a_time[$1]=$4
      a_ids[$1]=1
    }
    next
  }
  {
    if (NF < 3) next
    id=$1; title=$2; result=$3; timing=$4
    if (id in a_ids) {
      prev=a_result[id]
      if (prev == result) {
        printf "- %s — %s [%s]\n", id, title, result >> sm
      } else if (prev == "pass" && result == "fail") {
        printf "- %s — %s\n", id, title >> reg
      } else if (prev == "fail" && result == "pass") {
        printf "- %s — %s\n", id, title >> fix
      } else {
        printf "- %s — %s (%s → %s)\n", id, title, prev, result >> sm
      }
      if (a_time[id] != "null" && timing != "null" && a_time[id] != "" && timing != "") {
        at = a_time[id] + 0
        bt = timing + 0
        if (at > 0) {
          delta = bt - at
          pct = (delta / at) * 100
          printf "| %s — %s | %sms | %sms | %+0.1f%% |\n", id, title, at, bt, pct >> pf
        }
      }
      delete a_ids[id]
    } else {
      printf "- %s — %s [%s]\n", id, title, result >> ob
    }
  }
  END {
    for (id in a_ids) {
      printf "- %s — %s [%s]\n", id, a_title[id], a_result[id] >> oa
    }
  }
' "$tmp_a" "$tmp_b"

emit_section() {
  local heading="$1" file="$2"
  [ -s "$file" ] || return 0
  printf '%s\n' "$heading"
  cat "$file"
  printf '\n'
}

emit_section "### Regression introduced (A pass → B fail)"  "$regressions"
emit_section "### Regression fixed (A fail → B pass)"      "$fixes"
emit_section "### Only in round $RA"                       "$only_a"
emit_section "### New in round $RB"                        "$only_b"
emit_section "### Unchanged"                               "$same"

if [ -s "$perf" ]; then
  printf '### Performance delta\n\n'
  printf '| Case | %s | %s | Delta |\n' "$RA" "$RB"
  printf '|------|----|----|-------|\n'
  cat "$perf"
  printf '\n'
fi

# Summary counts. #237 — sanitise instead of `|| echo 0` to avoid the
# double-zero-with-newline corruption when grep matches zero lines.
cases_a=$(grep -c '' "$tmp_a" 2>/dev/null); case "$cases_a" in ''|*[!0-9]*) cases_a=0 ;; esac
cases_b=$(grep -c '' "$tmp_b" 2>/dev/null); case "$cases_b" in ''|*[!0-9]*) cases_b=0 ;; esac
reg_n=$(grep -c '' "$regressions" 2>/dev/null); case "$reg_n" in ''|*[!0-9]*) reg_n=0 ;; esac
fix_n=$(grep -c '' "$fixes" 2>/dev/null); case "$fix_n" in ''|*[!0-9]*) fix_n=0 ;; esac
printf '### Summary\n\n'
printf -- '- Cases: A=%s, B=%s\n' "$cases_a" "$cases_b"
printf -- '- Regressions: %s\n' "$reg_n"
printf -- '- Fixes: %s\n' "$fix_n"

rm -f "$tmp_a" "$tmp_b" "$regressions" "$fixes" "$only_a" "$only_b" "$same" "$perf"
exit 0
