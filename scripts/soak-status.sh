#!/usr/bin/env bash
# soak-status.sh — report progress against #245 A.2 dual-write soak exit criteria.
#
# Reads ~/.dev-studio/<project>/state/soak-start.json (the marker), then walks
# events/<YYYY-MM-DD>.jsonl files since `started_at`, counting:
#
#   - task cycles      → distinct task_uuids with brief_completed events
#   - release events   → release_state_changed | appstore_released
#   - sweep runs       → inbox_sweep_completed | audit_completed
#   - legacy domains   → distinct data.domain on legacy_artifact_read events
#
# Prints a human-readable status block + sets exit code 0 if all four exit
# criteria are met (ready for A.3), 2 if not, 1 on error (no soak active).
#
# Usage:
#   scripts/soak-status.sh <project-slug>
#   scripts/soak-status.sh <project-slug> --json   # machine-readable output

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    *)  if [ -z "$PROJECT" ]; then PROJECT="$arg"; else printf 'extra arg: %s\n' "$arg" >&2; exit 2; fi ;;
  esac
done

if [ -z "$PROJECT" ]; then
  printf 'usage: %s <project-slug> [--json]\n' "$(basename "$0")" >&2
  exit 2
fi

PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
MARKER="$PROJECT_ROOT/state/soak-start.json"
EVENTS_DIR="$PROJECT_ROOT/events"

if [ ! -f "$MARKER" ]; then
  printf 'soak-status: no soak active for %s (missing %s).\n' "$PROJECT" "$MARKER" >&2
  printf 'soak-status: start one with: scripts/soak-start.sh %s\n' "$PROJECT" >&2
  exit 1
fi

# Pull marker fields. Use awk rather than jq (jq isn't a hard dep elsewhere
# in scripts/) — the marker schema is tiny and stable.
STARTED_AT=$(awk -F'"' '/"started_at"/{print $4; exit}' "$MARKER")
EXPECTED_DOMAINS=$(awk '
  /"expected_legacy_domains"/ { in_arr=1; next }
  in_arr && /\]/              { in_arr=0; next }
  in_arr                      { gsub(/[",[:space:]]/, ""); if ($0) print $0 }
' "$MARKER")

if [ -z "$STARTED_AT" ]; then
  printf 'soak-status: marker malformed (no started_at): %s\n' "$MARKER" >&2
  exit 1
fi

# Build a regex of expected domains for grep -v filtering.
EXPECTED_RE=$(printf '%s\n' "$EXPECTED_DOMAINS" | paste -sd'|' -)

# Cross-platform epoch conversion. macOS `date -j -f` vs GNU `date -d`.
to_epoch() {
  local ts="$1"
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null; then return; fi
  date -d "$ts" +%s 2>/dev/null
}

START_EPOCH=$(to_epoch "$STARTED_AT") || {
  printf 'soak-status: cannot parse started_at=%s\n' "$STARTED_AT" >&2; exit 1
}

# Walk every events file (compressed or not) whose date >= start date.
START_DATE="${STARTED_AT%%T*}"
EVENT_FILES=$(find "$EVENTS_DIR" -maxdepth 1 -type f \
  \( -name '20*.jsonl' -o -name '20*.jsonl.gz' \) 2>/dev/null \
  | awk -v s="$START_DATE" -F/ '{f=$NF; d=substr(f,1,10); if (d >= s) print $0}' \
  | sort)

if [ -z "$EVENT_FILES" ]; then
  printf 'soak-status: no events under %s since %s.\n' "$EVENTS_DIR" "$START_DATE" >&2
fi

# Concatenate all eligible event files (jsonl + jsonl.gz) into one stream,
# parse each line with jq (handles nested data.* fields correctly — naive
# quote-splitting awk got fooled by producer.instance_id and similar). One
# pass; lexicographic ts comparison works because all events use zero-padded
# ISO-8601 in UTC.
read_events() {
  local f
  for f in $EVENT_FILES; do
    if [ "${f##*.}" = "gz" ]; then
      gunzip -c "$f" 2>/dev/null
    else
      cat "$f"
    fi
  done
}

TALLY=$(read_events | jq -rR --arg start_ts "$STARTED_AT" '
  fromjson? | select(.ts != null and .event != null and .ts >= $start_ts) |
  if .event == "brief_completed" and (.task // "") != "" then
    "task\t\(.task)"
  elif .event == "release_state_changed" or .event == "appstore_released" then
    "release"
  elif .event == "inbox_sweep_completed" or .event == "audit_completed" then
    "sweep"
  elif .event == "legacy_artifact_read" and (.data.domain // "") != "" then
    "domain\t\(.data.domain)"
  else empty end
' 2>/dev/null | awk -F'\t' '
  $1 == "task"    { tasks[$2]   = 1 }
  $1 == "release" { releases++     }
  $1 == "sweep"   { sweeps++       }
  $1 == "domain"  { domains[$2]++ }
  END {
    n = 0; for (t in tasks) n++
    printf "task_cycles\t%d\n", n
    printf "releases\t%d\n",   releases+0
    printf "sweeps\t%d\n",     sweeps+0
    for (d in domains) printf "domain\t%s\t%d\n", d, domains[d]
  }
')

TASK_CYCLES=$(printf '%s\n' "$TALLY" | awk -F'\t' '$1=="task_cycles"{print $2}')
RELEASES=$(printf '%s\n'    "$TALLY" | awk -F'\t' '$1=="releases"{print $2}')
SWEEPS=$(printf '%s\n'      "$TALLY" | awk -F'\t' '$1=="sweeps"{print $2}')
TASK_CYCLES=${TASK_CYCLES:-0}; RELEASES=${RELEASES:-0}; SWEEPS=${SWEEPS:-0}

# Domain accounting: split into expected vs unaccounted.
DOMAINS_OBSERVED=$(printf '%s\n' "$TALLY" | awk -F'\t' '$1=="domain"{printf "%s:%s\n", $2, $3}')
UNACCOUNTED=""
EXPECTED_HITS=""
if [ -n "$DOMAINS_OBSERVED" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    d="${line%%:*}"; c="${line##*:}"
    if printf '%s\n' "$EXPECTED_DOMAINS" | grep -qx "$d"; then
      EXPECTED_HITS="$EXPECTED_HITS $d=$c"
    else
      UNACCOUNTED="$UNACCOUNTED $d=$c"
    fi
  done <<EOF
$DOMAINS_OBSERVED
EOF
fi

EXPECTED_HITS=${EXPECTED_HITS# }
UNACCOUNTED=${UNACCOUNTED# }

# Pass/fail logic.
PASS_CYCLES=$([ "$TASK_CYCLES" -ge 30 ] && echo y || echo n)
PASS_REL=$(   [ "$RELEASES"    -ge 1  ] && echo y || echo n)
PASS_SWEEP=$( [ "$SWEEPS"      -ge 1  ] && echo y || echo n)
PASS_DOMAIN=$([ -z "$UNACCOUNTED" ] && echo y || echo n)

if [ "$JSON" -eq 1 ]; then
  # Tiny hand-rolled JSON — no jq dependency.
  printf '{"project":"%s","started_at":"%s","task_cycles":%d,"task_cycles_target":30,"releases":%d,"releases_target":1,"sweeps":%d,"sweeps_target":1,"expected_domains":"%s","unaccounted_domains":"%s","ready_for_a3":%s}\n' \
    "$PROJECT" "$STARTED_AT" "$TASK_CYCLES" "$RELEASES" "$SWEEPS" \
    "${EXPECTED_HITS:-none}" "${UNACCOUNTED:-none}" \
    "$([ "$PASS_CYCLES$PASS_REL$PASS_SWEEP$PASS_DOMAIN" = "yyyy" ] && echo true || echo false)"
else
  bar() {
    local cur="$1" tgt="$2" w=10 filled
    [ "$cur" -gt "$tgt" ] && cur="$tgt"
    filled=$(( cur * w / tgt ))
    printf '['
    i=0; while [ $i -lt $filled ];   do printf '#'; i=$((i+1)); done
    while [ $i -lt $w ];             do printf '.'; i=$((i+1)); done
    printf ']'
  }
  mark() { [ "$1" = "y" ] && printf 'PASS' || printf 'wait'; }

  printf '#245 A.2 soak — project=%s\n' "$PROJECT"
  printf 'started_at: %s\n' "$STARTED_AT"
  printf '\n'
  printf '  task cycles    %s %2d / 30   %s\n'   "$(bar "$TASK_CYCLES" 30)" "$TASK_CYCLES" "$(mark "$PASS_CYCLES")"
  printf '  release runs   %s %2d /  1   %s\n'   "$(bar "$RELEASES"     1)" "$RELEASES"    "$(mark "$PASS_REL")"
  printf '  sweep runs     %s %2d /  1   %s\n'   "$(bar "$SWEEPS"       1)" "$SWEEPS"      "$(mark "$PASS_SWEEP")"
  printf '\n'
  printf '  expected legacy_artifact_read domains: %s\n' "${EXPECTED_HITS:-none observed yet}"
  if [ -n "$UNACCOUNTED" ]; then
    printf '  UNACCOUNTED legacy_artifact_read domains (BLOCK exit): %s\n' "$UNACCOUNTED"
    printf '  → A.1 audit missed a reader. Investigate the caller, fix forward, soak continues.\n'
  else
    printf '  unaccounted-for domains: none  PASS\n'
  fi
  printf '\n'
  if [ "$PASS_CYCLES$PASS_REL$PASS_SWEEP$PASS_DOMAIN" = "yyyy" ]; then
    printf 'verdict: READY for A.3 (flip _lw_dual_write_enabled default to yaml-only).\n'
  else
    printf 'verdict: not yet — keep soaking under DUAL_WRITE_MODE=yaml-only.\n'
  fi
fi

[ "$PASS_CYCLES$PASS_REL$PASS_SWEEP$PASS_DOMAIN" = "yyyy" ] && exit 0 || exit 2
