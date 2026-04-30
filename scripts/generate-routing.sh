#!/usr/bin/env bash
# generate-routing.sh — emit a host-native skill-routing fragment.
#
# Reads every routing.yaml in the skill graph, joins with portability.yaml
# (only emitting skills compatible with the target host), filters by an
# optional domain set, and writes a clean markdown fragment to stdout.
#
# One source of truth → N host outputs. Adding a host = one row in
# hosts/registry.yaml; the same routing.yaml feeds every host.
#
# Usage:
#   scripts/generate-routing.sh <host>
#                                              # → stdout, no in-place edit
#   scripts/generate-routing.sh <host> --domains swift,swiftui
#                                              # → filter to skills declaring
#                                                  any of these domains
#   scripts/generate-routing.sh <host> --in-place <file>
#                                              # → replace the block bracketed
#                                                  by <!-- skill-routing:start
#                                                  host=<host> --> markers; if
#                                                  the markers are absent, the
#                                                  fragment is appended at EOF
#                                                  with markers added.
#
# Output shape:
#   <!-- skill-routing:start host=<host> generated=<iso8601> -->
#   | Trigger | Skill |
#   |---|---|
#   | <natural-language phrase> | `/<slash-command>` |
#   ...
#   <!-- skill-routing:end -->
#
# Non-portable skills (their portability.yaml does not list <host>) are
# silently omitted. Skills without a routing.yaml are also omitted (they're
# not user-invokable from chat).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if ! command -v yq >/dev/null 2>&1; then
  printf 'generate-routing: yq is required\n' >&2
  exit 2
fi

HOST=""
DOMAIN_FILTER=""
IN_PLACE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --domains) shift; DOMAIN_FILTER="$1" ;;
    --in-place) shift; IN_PLACE_FILE="$1" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) printf 'generate-routing: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$HOST" ]; then HOST="$1"
      else printf 'generate-routing: extra argument "%s"\n' "$1" >&2; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$HOST" ]; then
  printf 'usage: generate-routing.sh <host> [--domains a,b] [--in-place <file>]\n' >&2
  exit 2
fi

# Auto-detect .skill-domains in cwd and repo root when no explicit --domains
# filter was passed. The file is one domain per line; comments (`#`) and
# blank lines ignored. Intent: per-project context lean — Swift skills do
# not appear in routing for a Python project, etc.
if [ -z "$DOMAIN_FILTER" ]; then
  for dom_file in "$PWD/.skill-domains" "$REPO_ROOT/.skill-domains"; do
    if [ -f "$dom_file" ]; then
      DOMAIN_FILTER=$(awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); printf "%s,", $0 }
      ' "$dom_file" | sed 's/,$//')
      break
    fi
  done
fi

REGISTRY="$REPO_ROOT/hosts/registry.yaml"
if [ ! -f "$REGISTRY" ]; then
  printf 'generate-routing: hosts/registry.yaml not found\n' >&2
  exit 2
fi

if ! yq -r 'keys | .[]' "$REGISTRY" 2>/dev/null | grep -Fxq "$HOST"; then
  printf 'generate-routing: host "%s" is not declared in hosts/registry.yaml\n' "$HOST" >&2
  exit 2
fi

# Collect routing.yaml files in deterministic order. Uses a while-read loop
# instead of `mapfile` so the script runs on macOS's stock bash 3.2.
ROUTING_FILES_LIST=$(
  cd "$REPO_ROOT" && \
  find achilles argus chanakya .claude/skills skills/owned skills/vendored \
       -name routing.yaml -type f 2>/dev/null \
    | sort
)

# Build the fragment body in a temp file (header markers + table).
TMP_BODY=$(mktemp -t routing-body.XXXXXX)
trap 'rm -f "$TMP_BODY"' EXIT

# Convert comma-separated domain filter to space-separated.
DOMAIN_LIST=""
if [ -n "$DOMAIN_FILTER" ]; then
  DOMAIN_LIST=$(printf '%s' "$DOMAIN_FILTER" | tr ',' ' ')
fi

domain_match() {
  # $1 — space-separated domains declared by the skill.
  # Returns 0 if the skill matches the filter (or if no filter is active).
  local declared="$1" wanted="$DOMAIN_LIST" d w
  [ -z "$wanted" ] && return 0
  for d in $declared; do
    for w in $wanted; do
      if [ "$d" = "$w" ]; then return 0; fi
    done
  done
  return 1
}

emit_table_header() {
  printf '| Trigger | Skill |\n'
  printf '|---|---|\n'
}

ROW_COUNT=0
ROWS_TMP=$(mktemp -t routing-rows.XXXXXX)
trap 'rm -f "$TMP_BODY" "$ROWS_TMP"' EXIT

while IFS= read -r routing; do
  [ -z "$routing" ] && continue
  abs="$REPO_ROOT/$routing"
  [ -f "$abs" ] || continue
  skill_dir=$(dirname "$abs")
  portability="$skill_dir/portability.yaml"

  # Default behavior when portability.yaml is absent: claude-code only.
  if [ -f "$portability" ]; then
    if ! yq -r '.hosts[]' "$portability" 2>/dev/null | grep -Fxq -e "$HOST" -e "all"; then
      continue
    fi
  else
    [ "$HOST" != "claude-code" ] && continue
  fi

  name=$(yq -r '.name' "$abs" 2>/dev/null)
  slash=$(yq -r '.invocation.slash_command // ""' "$abs" 2>/dev/null)
  triggers=$(yq -r '.invocation.triggers[]? // ""' "$abs" 2>/dev/null)
  declared_domains=$(yq -r '.domains[]? // ""' "$abs" 2>/dev/null | tr '\n' ' ')

  domain_match "$declared_domains" || continue

  # Each trigger is a row in the table; if no triggers given, fall back to
  # the slash command alone.
  if [ -z "$triggers" ] && [ -n "$slash" ]; then
    printf '| `%s` | `%s` |\n' "$slash" "${slash:-/$name}" >>"$ROWS_TMP"
    ROW_COUNT=$((ROW_COUNT + 1))
    continue
  fi

  invocation_label="${slash:-/$name}"
  while IFS= read -r trig; do
    [ -z "$trig" ] && continue
    # Pipe characters in trigger phrases break the table — escape them.
    safe_trig=${trig//|/\\|}
    printf '| %s | `%s` |\n' "$safe_trig" "$invocation_label" >>"$ROWS_TMP"
    ROW_COUNT=$((ROW_COUNT + 1))
  done <<<"$triggers"
done <<<"$ROUTING_FILES_LIST"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '<!-- skill-routing:start host=%s generated=%s -->\n' "$HOST" "$NOW"
  if [ "$ROW_COUNT" -gt 0 ]; then
    emit_table_header
    cat "$ROWS_TMP"
  else
    printf '_No skills declared compatible with host=%s' "$HOST"
    [ -n "$DOMAIN_FILTER" ] && printf ' under domains=%s' "$DOMAIN_FILTER"
    printf '._\n'
  fi
  printf '<!-- skill-routing:end -->\n'
} >"$TMP_BODY"

if [ -z "$IN_PLACE_FILE" ]; then
  cat "$TMP_BODY"
  exit 0
fi

# In-place: replace the bracketed block, or append if markers absent.
target="$IN_PLACE_FILE"
if [ ! -f "$target" ]; then
  cat "$TMP_BODY" > "$target"
  exit 0
fi

start_marker="<!-- skill-routing:start host=$HOST"
end_marker="<!-- skill-routing:end -->"

if grep -Fq "$start_marker" "$target"; then
  awk -v body_file="$TMP_BODY" -v sm="$start_marker" -v em="$end_marker" '
    BEGIN { while ((getline line < body_file) > 0) body = body line "\n"; close(body_file) }
    {
      if (in_block) {
        if (index($0, em)) { in_block = 0 }
        next
      }
      if (index($0, sm)) {
        printf "%s", body
        in_block = 1
        next
      }
      print
    }
  ' "$target" > "$target.tmp"
  mv "$target.tmp" "$target"
else
  printf '\n' >>"$target"
  cat "$TMP_BODY" >>"$target"
fi
