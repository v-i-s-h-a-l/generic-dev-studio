#!/usr/bin/env bash
# next-task-id.sh — deterministic allocator for human-readable legacy_task_id.
#
# Post-Phase-2.6 canonical task id is a UUIDv7. The `legacy_task_id:` field
# (T001, T002, …) is a display convenience users still think in. This script
# is the single source of truth for "what's the next free T-number".
#
# **Block-aware allocation (host-agnostic).** When the project has a registry
# at `<plans-dir>/task-id-allocation.yaml`, allocations honor 100-task topic
# blocks declared there. Sealed-gap ranges are refused. Without a registry the
# allocator falls back to legacy max+1 behavior with a stderr warning.
#
# Usage:
#   scripts/next-task-id.sh                         # default block from registry
#   scripts/next-task-id.sh --block=<name>          # next free inside <name>'s range
#   scripts/next-task-id.sh --prefix=TBUILD         # -> TBUILD-5 (TBUILD/TUNIT bypass blocks)
#   scripts/next-task-id.sh --prefix=TUNIT          # -> TUNIT-3
#   scripts/next-task-id.sh --project=<slug>        # override auto-detection
#   scripts/next-task-id.sh --list-blocks           # print registry as table
#   scripts/next-task-id.sh --allocate-block <name> <start>-<end> \
#       [--description="..."] [--default]           # add a new block to registry
#   scripts/next-task-id.sh --explain               # also print per-source counts (stderr)
#
# Exit codes:
#   0  next id printed to stdout
#   2  cannot resolve project
#   3  block sealed / not found / range exhausted
#   4  registry write failed
#   64 bad args

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PREFIX="T"
PROJECT=""
EXPLAIN=0
BLOCK=""
LIST_BLOCKS=0
ALLOCATE_BLOCK=""
ALLOCATE_RANGE=""
ALLOCATE_DESC=""
ALLOCATE_DEFAULT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix=*)         PREFIX="${1#--prefix=}" ;;
    --project=*)        PROJECT="${1#--project=}" ;;
    --block=*)          BLOCK="${1#--block=}" ;;
    --list-blocks)      LIST_BLOCKS=1 ;;
    --allocate-block)   shift; ALLOCATE_BLOCK="${1:-}"; shift; ALLOCATE_RANGE="${1:-}"; continue ;;
    --description=*)    ALLOCATE_DESC="${1#--description=}" ;;
    --default)          ALLOCATE_DEFAULT=1 ;;
    --explain)          EXPLAIN=1 ;;
    --help|-h)          sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                  printf 'unknown arg: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

[ -z "$PROJECT" ] && PROJECT=$(resolve_project 2>/dev/null || echo "")
[ -z "$PROJECT" ] && { printf 'cannot resolve project — pass --project=<slug>\n' >&2; exit 2; }

PLANS_DIR=$(resolve_plans_dir_for "$PROJECT")
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
EVENTS_DIR=$(resolve_events_dir_for "$PROJECT")
REGISTRY="$PLANS_DIR/task-id-allocation.yaml"

# ---------- Registry parsing (no yq dependency; minimal block-aware reader) ----

# Emit one TSV row per block: name<TAB>start<TAB>end<TAB>state
# Lines processed: `  - name: legacy` / `    range: [1, 371]` / `    state: sealed`.
parse_blocks() {
  [ -f "$REGISTRY" ] || return 0
  awk '
    /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {
      if (name != "") print name"\t"start"\t"end"\t"state
      name = $0; sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", name); gsub(/[[:space:]"]+$/, "", name)
      start=""; end=""; state=""
      next
    }
    /^[[:space:]]+range:[[:space:]]*\[/ {
      r = $0; sub(/^[[:space:]]+range:[[:space:]]*\[/, "", r); sub(/\].*$/, "", r); gsub(/[[:space:]]/, "", r)
      n = split(r, parts, ",")
      if (n >= 2) { start = parts[1]; end = parts[2] }
      next
    }
    /^[[:space:]]+state:[[:space:]]*/ {
      state = $0; sub(/^[[:space:]]+state:[[:space:]]*/, "", state); gsub(/[[:space:]"]+$/, "", state)
      next
    }
    /^[a-zA-Z]/ {
      # top-level key — block list ended
      if (name != "") { print name"\t"start"\t"end"\t"state; name="" }
    }
    END {
      if (name != "") print name"\t"start"\t"end"\t"state
    }
  ' "$REGISTRY"
}

read_default_block() {
  [ -f "$REGISTRY" ] || return 0
  awk '/^default_block:[[:space:]]*/ { v=$0; sub(/^default_block:[[:space:]]*/, "", v); gsub(/[[:space:]"]+$/, "", v); print v; exit }' "$REGISTRY"
}

# ---------- --list-blocks ---------------------------------------------------

if [ "$LIST_BLOCKS" = "1" ]; then
  if [ ! -f "$REGISTRY" ]; then
    printf 'no registry at %s — using legacy max+1 allocation\n' "$REGISTRY" >&2
    exit 0
  fi
  printf 'registry: %s\n' "$REGISTRY"
  printf 'default_block: %s\n\n' "$(read_default_block)"
  printf '%-22s %-12s %-12s %s\n' "BLOCK" "RANGE" "STATE" "NEXT-FREE"
  parse_blocks | while IFS=$'\t' read -r bname bstart bend bstate; do
    if [ "$bstate" = "sealed-gap" ] || [ "$bstate" = "sealed" ]; then
      next="—"
    else
      max_in_block=$(grep -hEo 'legacy_task_id: *"?T[0-9]+' "$TASKS_DIR"/*.yaml 2>/dev/null \
        | grep -oE '[0-9]+$' \
        | awk -v s="$bstart" -v e="$bend" '$1>=s && $1<=e' \
        | sort -n | tail -1)
      if [ -z "$max_in_block" ]; then
        next=$(printf 'T%03d' "$bstart")
      elif [ "$max_in_block" -ge "$bend" ]; then
        next="EXHAUSTED"
      else
        next=$(printf 'T%03d' $((max_in_block + 1)))
      fi
    fi
    printf '%-22s %-12s %-12s %s\n' "$bname" "[$bstart, $bend]" "$bstate" "$next"
  done
  exit 0
fi

# ---------- --allocate-block ------------------------------------------------

if [ -n "$ALLOCATE_BLOCK" ]; then
  [ -z "$ALLOCATE_RANGE" ] && { printf 'usage: --allocate-block <name> <start>-<end>\n' >&2; exit 64; }
  start=$(printf '%s' "$ALLOCATE_RANGE" | cut -d- -f1)
  end=$(printf '%s' "$ALLOCATE_RANGE" | cut -d- -f2)
  case "$start$end" in *[!0-9]*) printf 'range must be <int>-<int>: got %s\n' "$ALLOCATE_RANGE" >&2; exit 64 ;; esac
  [ "$start" -lt "$end" ] || { printf 'range start must be < end\n' >&2; exit 64; }

  # Refuse overlap with existing blocks.
  if [ -f "$REGISTRY" ]; then
    while IFS=$'\t' read -r bname bstart bend _; do
      [ -z "$bname" ] && continue
      if [ "$start" -le "$bend" ] && [ "$end" -ge "$bstart" ]; then
        printf 'range [%s, %s] overlaps existing block %s [%s, %s]\n' "$start" "$end" "$bname" "$bstart" "$bend" >&2
        exit 3
      fi
      if [ "$bname" = "$ALLOCATE_BLOCK" ]; then
        printf 'block %s already exists\n' "$ALLOCATE_BLOCK" >&2; exit 3
      fi
    done < <(parse_blocks)
  else
    # Bootstrap a registry from scratch.
    mkdir -p "$PLANS_DIR" || { printf 'cannot create plans dir\n' >&2; exit 4; }
    {
      printf 'schema_version: 1\n'
      printf 'prefix: T\n'
      printf 'default_block: %s\n' "$ALLOCATE_BLOCK"
      printf 'ratified_at: %s\n' "$(date -u +%Y-%m-%d)"
      printf 'blocks: []\n'
    } > "$REGISTRY" || { printf 'cannot write registry\n' >&2; exit 4; }
  fi

  # Append the block. Replace `blocks: []` if present, else append before EOF.
  tmp=$(mktemp) || { printf 'mktemp failed\n' >&2; exit 4; }
  if grep -q '^blocks: \[\]' "$REGISTRY"; then
    sed 's/^blocks: \[\]/blocks:/' "$REGISTRY" > "$tmp"
  else
    cp "$REGISTRY" "$tmp"
  fi
  {
    printf '  - name: %s\n' "$ALLOCATE_BLOCK"
    printf '    range: [%s, %s]\n' "$start" "$end"
    printf '    state: open\n'
    [ -n "$ALLOCATE_DESC" ] && printf '    description: %s\n' "\"$ALLOCATE_DESC\""
  } >> "$tmp"

  if [ "$ALLOCATE_DEFAULT" = "1" ]; then
    if grep -q '^default_block:' "$tmp"; then
      sed -i.bak "s/^default_block:.*/default_block: $ALLOCATE_BLOCK/" "$tmp" && rm -f "$tmp.bak"
    else
      printf 'default_block: %s\n' "$ALLOCATE_BLOCK" >> "$tmp"
    fi
  fi
  mv "$tmp" "$REGISTRY" || { printf 'registry replace failed\n' >&2; exit 4; }

  printf 'allocated block %s [%s, %s]%s\n' "$ALLOCATE_BLOCK" "$start" "$end" \
    "$([ "$ALLOCATE_DEFAULT" = "1" ] && echo " (default)")" >&2
  exit 0
fi

# ---------- Standard allocation ---------------------------------------------

# TBUILD/TUNIT and other non-T prefixes bypass blocks entirely.
if [ "$PREFIX" = "T" ]; then
  SEP=''
else
  SEP='-'
fi
TOKEN_RE="${PREFIX}${SEP}[0-9]+"

collect_numbers() {
  if [ -d "$TASKS_DIR" ]; then
    grep -hEo "legacy_task_id: *\"?${TOKEN_RE}" "$TASKS_DIR"/*.yaml 2>/dev/null \
      | grep -oE '[0-9]+$'
  fi
  if [ -d "$EVENTS_DIR" ]; then
    grep -hoE "\"${TOKEN_RE}\"" "$EVENTS_DIR"/*.jsonl 2>/dev/null \
      | grep -oE '[0-9]+'
  fi
}

# Block-aware path applies only to PREFIX="T" with a registry present.
if [ "$PREFIX" = "T" ] && [ -f "$REGISTRY" ]; then
  if [ -z "$BLOCK" ]; then
    BLOCK=$(read_default_block)
    [ -z "$BLOCK" ] && { printf 'registry has no default_block; pass --block=<name> or --allocate-block first\n' >&2; exit 3; }
  fi

  # Resolve block range + state.
  brow=$(parse_blocks | awk -F'\t' -v n="$BLOCK" '$1==n {print; exit}')
  [ -z "$brow" ] && { printf 'block %s not found in %s\n' "$BLOCK" "$REGISTRY" >&2; exit 3; }
  bstart=$(printf '%s' "$brow" | cut -f2)
  bend=$(printf '%s' "$brow" | cut -f3)
  bstate=$(printf '%s' "$brow" | cut -f4)
  case "$bstate" in
    sealed|sealed-gap) printf 'block %s is %s — refusing to allocate\n' "$BLOCK" "$bstate" >&2; exit 3 ;;
    open) ;;
    *) printf 'block %s has unknown state %s\n' "$BLOCK" "$bstate" >&2; exit 3 ;;
  esac

  # Allocation truth = tasks YAML only. Events log is intent — phantom refs
  # (events without backing task YAML) are surfaced as warnings but don't
  # increment max_in_block. Otherwise stale plans permanently exhaust blocks.
  max_in_block=$(grep -hEo 'legacy_task_id: *"?T[0-9]+' "$TASKS_DIR"/*.yaml 2>/dev/null \
    | grep -oE '[0-9]+$' \
    | awk -v s="$bstart" -v e="$bend" '$1>=s && $1<=e' \
    | sort -n | tail -1)
  if [ -z "$max_in_block" ]; then
    next_n=$bstart
  else
    next_n=$((max_in_block + 1))
  fi
  if [ "$next_n" -gt "$bend" ]; then
    printf 'block %s [%s, %s] exhausted; allocate a new block via --allocate-block\n' "$BLOCK" "$bstart" "$bend" >&2
    exit 3
  fi

  # Phantom-event audit: any in-block id mentioned in events without a task
  # YAML signals either an in-flight allocation (recent) or a stale plan (old).
  # Print as a single advisory line; never block.
  if [ -d "$EVENTS_DIR" ]; then
    phantoms=$({
      grep -hoE '"T[0-9]+"' "$EVENTS_DIR"/*.jsonl 2>/dev/null | tr -d '"' | sort -u
    } | awk -v s="$bstart" -v e="$bend" '
        { n=substr($1,2)+0; if (n>=s && n<=e) print $1 }
      ' | while read -r tid; do
        n=${tid#T}; n=$((10#$n))
        # Strip leading zeros for grep match.
        if ! grep -qE "legacy_task_id: *\"?T0*${n}([^0-9]|$)" "$TASKS_DIR"/*.yaml 2>/dev/null; then
          printf '%s ' "$tid"
        fi
      done)
    if [ -n "$phantoms" ]; then
      printf 'note: phantom event refs in block %s (event-only, no task YAML): %s\n' "$BLOCK" "$phantoms" >&2
    fi
  fi

  if [ "$EXPLAIN" = "1" ]; then
    printf 'next-task-id: project=%s prefix=%s block=%s range=[%s,%s] max-in-block=%s next=%s\n' \
      "$PROJECT" "$PREFIX" "$BLOCK" "$bstart" "$bend" "${max_in_block:-none}" "$next_n" >&2
  fi
  printf 'T%03d\n' "$next_n"
  exit 0
fi

# ---------- Legacy fallback (no registry, or non-T prefix) ------------------

if [ "$PREFIX" = "T" ] && [ ! -f "$REGISTRY" ]; then
  printf 'warning: no registry at %s — using legacy max+1 allocation. Create one via --allocate-block.\n' "$REGISTRY" >&2
fi

src_yaml=0 src_events=0
if [ "$EXPLAIN" = "1" ]; then
  [ -d "$TASKS_DIR" ] && src_yaml=$(
    grep -hEo "legacy_task_id: *\"?${TOKEN_RE}" "$TASKS_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' '
  )
  [ -d "$EVENTS_DIR" ] && src_events=$(
    grep -hoE "\"${TOKEN_RE}\"" "$EVENTS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' '
  )
fi

max_n=$(collect_numbers | sort -n | tail -1)
[ -z "$max_n" ] && max_n=0
next_n=$(( max_n + 1 ))

if [ "$EXPLAIN" = "1" ]; then
  printf 'next-task-id: project=%s prefix=%s max=%s next=%s sources=yaml:%s,events:%s\n' \
    "$PROJECT" "$PREFIX" "$max_n" "$next_n" "$src_yaml" "$src_events" >&2
fi

if [ "$PREFIX" = "T" ]; then
  printf 'T%03d\n' "$next_n"
else
  printf '%s-%d\n' "$PREFIX" "$next_n"
fi
