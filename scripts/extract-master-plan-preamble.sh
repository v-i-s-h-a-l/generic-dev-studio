#!/usr/bin/env bash
# extract-master-plan-preamble.sh — Stage A.0 / #273 bootstrap
#
# One-shot helper that splits an existing plans/chanakya-master.md into:
#
#   plans/master-plan-preamble.md  — editorial prose between the title and
#                                    the first task heading (### Tnnn …),
#                                    minus the `## Build Debt` block which
#                                    extracts to YAML (see below).
#   plans/build-debt.yaml          — Build Debt counter, state, etc., per
#                                    _shared/schemas/build-debt.md.
#
# Idempotent: if either output already exists, the corresponding extraction
# step skips. Run it once per project to bootstrap; safe to re-run.
#
# After extraction, scripts/render-master-plan.sh becomes the only writer of
# chanakya-master.md (wired into sweep-ingest end-of-run).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=$(resolve_project 2>/dev/null) || {
  printf 'extract-master-plan-preamble: no project context\n' >&2
  exit 0
}
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
PLANS_DIR="$PROJECT_ROOT/plans"
MASTER="$PLANS_DIR/chanakya-master.md"
PREAMBLE_OUT="$PLANS_DIR/master-plan-preamble.md"
BUILD_DEBT_OUT="$PLANS_DIR/build-debt.yaml"

if [ ! -f "$MASTER" ]; then
  printf 'extract-master-plan-preamble: no master-plan at %s — nothing to extract\n' "$MASTER" >&2
  exit 0
fi

# ---- Preamble extraction ---------------------------------------------------

extract_preamble() {
  if [ -f "$PREAMBLE_OUT" ]; then
    printf 'preamble already exists — skipping (%s)\n' "$PREAMBLE_OUT" >&2
    return 0
  fi
  local tmp
  tmp=$(mktemp "${PREAMBLE_OUT}.tmp.XXXXXX") || return 2
  # Capture everything between (exclusive) the first `# <project> — Master Plan`
  # title and the first `### ` task heading or `## Active Tasks` / `## Release
  # Log` section (whichever comes first — those are projector-rendered).
  # Drop the `## Build Debt` block since that extracts to YAML separately.
  # Keep `## Dashboard`, `## Module Index`, `## Argus-Skipped Merges`,
  # `## Blocked on External Input`, etc. Strip `---` separators.
  awk '
    BEGIN { in_title=0; in_build_debt=0 }
    /^# / { in_title=1; next }
    in_title && /^### / { exit }
    in_title && /^## Active Tasks/ { exit }
    in_title && /^## Release Log/ { exit }
    in_title && /^## Build Debt/ { in_build_debt=1; next }
    in_title && in_build_debt && /^## / && !/^## Build Debt/ { in_build_debt=0 }
    in_title && in_build_debt { next }
    in_title && /^---[[:space:]]*$/ { next }
    in_title { print }
  ' "$MASTER" > "$tmp" || { rm -f "$tmp"; return 2; }
  # Strip trailing blank lines.
  awk 'NF{p=1} p{print}' "$tmp" | awk '{lines[NR]=$0} END {for(i=NR;i>=1;i--){if(lines[i]!=""){last=i;break}}; for(i=1;i<=last;i++)print lines[i]}' > "${tmp}.2" || { rm -f "$tmp" "${tmp}.2"; return 2; }
  mv "${tmp}.2" "$PREAMBLE_OUT" || { rm -f "$tmp" "${tmp}.2"; return 2; }
  rm -f "$tmp"
  printf 'wrote %s\n' "$PREAMBLE_OUT" >&2
}

# ---- Build-debt extraction -------------------------------------------------

extract_build_debt() {
  if [ -f "$BUILD_DEBT_OUT" ]; then
    printf 'build-debt.yaml already exists — skipping (%s)\n' "$BUILD_DEBT_OUT" >&2
    return 0
  fi
  command -v yq >/dev/null 2>&1 || { printf 'extract-build-debt: yq required\n' >&2; return 2; }

  # Pull the `## Build Debt` block lines.
  local block
  block=$(awk '
    /^## Build Debt/ { in_block=1; next }
    in_block && /^## / { exit }
    in_block { print }
  ' "$MASTER")

  if [ -z "$block" ]; then
    printf 'extract-build-debt: no `## Build Debt` block in %s — seeding defaults\n' "$MASTER" >&2
    block=""
  fi

  # Field extraction. Each `_field <regex> <default>` parses the matching line
  # from $block; emits the captured value or the default. All values are
  # plain-string at this stage; YAML quoting happens below.
  _field_after() {
    local prefix="$1" default="${2:-}"
    local v
    v=$(printf '%s\n' "$block" | awk -v pre="$prefix" '
      $0 ~ pre {
        line=$0
        sub(pre, "", line)
        sub(/^[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    ')
    [ -z "$v" ] && v="$default"
    printf '%s' "$v"
  }

  local counter_line state last_green last_sha unverified open_check blocked_by next_n broken
  counter_line=$(_field_after '^- Counter:' '0')
  # `0 / warn@6 / block@12` — extract leading int.
  local counter warn_at block_at
  counter=$(printf '%s' "$counter_line" | awk '{print $1+0}')
  warn_at=$(printf '%s' "$counter_line" | grep -oE 'warn@[0-9]+' | sed 's/warn@//')
  block_at=$(printf '%s' "$counter_line" | grep -oE 'block@[0-9]+' | sed 's/block@//')
  [ -z "$warn_at" ] && warn_at=6
  [ -z "$block_at" ] && block_at=12

  state=$(_field_after '^- State:' 'silent')
  # Strip any trailing comment.
  state=$(printf '%s' "$state" | awk '{print $1}')
  case "$state" in
    silent|warn|block|paused|warned|blocked) ;;
    *) state="silent" ;;
  esac
  # Normalize legacy `warned`/`blocked` to `warn`/`block`.
  [ "$state" = "warned" ] && state="warn"
  [ "$state" = "blocked" ] && state="block"

  last_green=$(_field_after '^- Last green:' '')
  last_sha=$(_field_after '^- Last green SHA:' '')
  unverified=$(_field_after '^- Unverified since:' '')
  open_check=$(_field_after '^- Open check task:' '')
  blocked_by=$(_field_after '^- Blocked by:' '')
  next_n=$(_field_after '^- Next TBUILD n:' '1')
  broken=$(_field_after '^- Broken commit:' '')

  # Normalize `—` and similar em-dash sentinels to YAML null.
  _to_null_or_quoted() {
    local v="$1"
    case "$v" in
      ''|'—'|'-'|'null'|'None') printf 'null' ;;
      *) printf '"%s"' "$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')" ;;
    esac
  }

  # Parse `[T010, T011[overridden], T012]` into a YAML list. Empty / `[]` →
  # empty list.
  _list_or_empty() {
    local v="$1"
    v="${v#[}"; v="${v%]}"
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$v" ]; then
      printf '[]'
      return
    fi
    local out="["
    local first=1
    local IFS=','
    local item
    for item in $v; do
      item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$item" ] && continue
      if [ "$first" = "1" ]; then
        first=0
      else
        out="$out, "
      fi
      out="$out\"$(printf '%s' "$item" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    done
    out="$out]"
    printf '%s' "$out"
  }

  local lg lsh oct bk bb un_list ts
  lg=$(_to_null_or_quoted "$last_green")
  lsh=$(_to_null_or_quoted "$last_sha")
  oct=$(_to_null_or_quoted "$open_check")
  bk=$(_to_null_or_quoted "$broken")
  bb=$(_to_null_or_quoted "$blocked_by")
  un_list=$(_list_or_empty "$unverified")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$(dirname "$BUILD_DEBT_OUT")" || return 2
  cat > "$BUILD_DEBT_OUT" <<EOF
schema_version: {name: build-debt, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
counter: $counter
state: $state
warn_at: $warn_at
block_at: $block_at
last_green: $lg
last_green_sha: $lsh
unverified_since: $un_list
broken_commit_sha: $bk
open_check_task: $oct
blocked_by: $bb
next_tbuild_n: $next_n
notes: null
updated_at: $ts
EOF
  printf 'wrote %s (counter=%s state=%s)\n' "$BUILD_DEBT_OUT" "$counter" "$state" >&2
}

extract_preamble || { printf 'extract-preamble failed\n' >&2; exit 2; }
extract_build_debt || { printf 'extract-build-debt failed\n' >&2; exit 2; }

exit 0
