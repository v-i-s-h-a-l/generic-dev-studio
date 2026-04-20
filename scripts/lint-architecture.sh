#!/usr/bin/env bash
# lint-architecture.sh — enforces router-pattern + singleton invariants.
#
# Usage:
#   scripts/lint-architecture.sh            # lint every matching file (standalone)
#   scripts/lint-architecture.sh --staged   # lint only staged files (pre-commit)
#
# Exit 0 on pass (warnings allowed on stderr). Exit 1 on any block-tier
# violation. Error lines follow:
#   <CODE>:<file>[:<line>]:<detail> | <fix-hint>
# See _shared/enforcement-contract.md for the full code table + fix recipes.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

STAGED=0
if [ "${1:-}" = "--staged" ]; then
  STAGED=1
fi

ERRORS=0
WARNINGS=0

emit_error() {
  printf '%s\n' "$1"
  ERRORS=$((ERRORS + 1))
}

emit_warn() {
  printf '%s\n' "$1" >&2
  WARNINGS=$((WARNINGS + 1))
}

# Resolve the file set to lint. Staged mode intersects the full candidate list
# with `git diff --cached --name-only`. Standalone lints everything.
collect_candidates() {
  find "$REPO_ROOT/_shared" -maxdepth 1 -type f -name '*.md' 2>/dev/null
  find "$REPO_ROOT" -mindepth 3 -maxdepth 3 -type f -path '*/modes/*.md' 2>/dev/null
  find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null
}

filter_staged() {
  local staged
  staged=$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
  [ -z "$staged" ] && return 0
  local f rel
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#"$REPO_ROOT/"}"
    if printf '%s\n' "$staged" | grep -Fxq "$rel"; then
      printf '%s\n' "$f"
    fi
  done
}

# Frontmatter extraction — print lines 2..N-1 where line 1 and line N are '---'.
extract_frontmatter() {
  local file="$1"
  awk 'NR==1 && $0=="---" {flag=1; next}
       flag && $0=="---" {exit}
       flag {print}' "$file"
}

# Has a top-of-file YAML frontmatter block.
has_frontmatter() {
  local file="$1"
  head -n 1 "$file" 2>/dev/null | grep -Fxq '---'
}

# Strip frontmatter and fenced code blocks; print only prose lines.
prose_only() {
  local file="$1"
  awk '
    BEGIN { in_fm=0; fm_done=0; in_code=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm==1 && $0=="---" { in_fm=0; fm_done=1; next }
    in_fm==1 { next }
    /^```/ { in_code = 1 - in_code; next }
    in_code==1 { next }
    { print }
  ' "$file"
}

# ---------- E_FRONTMATTER ----------
check_frontmatter() {
  local file="$1" required="$2" fm keys missing key
  fm=$(extract_frontmatter "$file")
  if [ -z "$fm" ]; then
    emit_error "E_FRONTMATTER:$file:missing=$required | add YAML frontmatter with $required at top of file"
    return 1
  fi
  missing=""
  for key in $required; do
    if ! printf '%s\n' "$fm" | grep -qE "^${key}:"; then
      missing="${missing:+$missing,}$key"
    fi
  done
  if [ -n "$missing" ]; then
    emit_error "E_FRONTMATTER:$file:missing=$missing | add missing keys to frontmatter"
    return 1
  fi
  return 0
}

# ---------- E_ROUTER_SIZE ----------
check_router_size() {
  local skill_md="$1" count
  count=$(prose_only "$skill_md" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  if [ "$count" -gt 100 ]; then
    emit_error "E_ROUTER_SIZE:$skill_md:$count>100 | move mode-specific prose to modes/<pack>.md"
  fi
}

# ---------- E_CROSS_MODE_LOAD ----------
check_cross_mode_load() {
  local mode_file="$1" line matches
  matches=$(grep -nE 'modes/[a-z0-9-]+\.md' "$mode_file" 2>/dev/null || true)
  [ -z "$matches" ] && return 0
  printf '%s\n' "$matches" | while IFS= read -r line; do
    local ln="${line%%:*}"
    emit_error "E_CROSS_MODE_LOAD:$mode_file:$ln | mode packs communicate via snapshots, not imports"
  done
}

# ---------- E_MISSING_SNAPSHOTS_DECL ----------
check_snapshots_decl() {
  local mode_file="$1" fm
  fm=$(extract_frontmatter "$mode_file")
  if ! printf '%s\n' "$fm" | grep -qE '^snapshots:'; then
    emit_error "E_MISSING_SNAPSHOTS_DECL:$mode_file | add 'snapshots: []' to frontmatter"
  fi
}

# ---------- W_MODE_SIZE ----------
check_mode_size() {
  local mode_file="$1" count
  count=$(prose_only "$mode_file" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  if [ "$count" -gt 600 ]; then
    emit_error "E_MODE_SIZE:$mode_file:$count>600 | split this mode pack — too large"
  elif [ "$count" -gt 400 ]; then
    emit_warn "W_MODE_SIZE:$mode_file:$count>400 | consider splitting mode pack"
  fi
}

# ---------- W_SNAPSHOT_FRESHNESS ----------
check_snapshot_freshness() {
  local mode_file="$1" fm decl
  fm=$(extract_frontmatter "$mode_file")
  decl=$(printf '%s\n' "$fm" | grep -E '^snapshots:' | head -n 1)
  # Only relevant if at least one snapshot is declared (not `[]` nor empty).
  if printf '%s\n' "$decl" | grep -qE '^snapshots:[[:space:]]*(\[\]|\[\s*\])?[[:space:]]*$'; then
    return 0
  fi
  if ! grep -qiE 'stale|freshness' "$mode_file"; then
    emit_warn "W_SNAPSHOT_FRESHNESS:$mode_file | declares snapshots but no stale/freshness handling discussed"
  fi
}

# ---------- W_BUDGET_DRIFT ----------
check_budget_drift() {
  local mode_file="$1" budgets_file key budget words est
  budgets_file="$REPO_ROOT/_shared/token-budgets.json"
  [ -f "$budgets_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # Key: "<agent>/<mode>" — derived from path */<agent>/modes/<mode>.md.
  key=$(printf '%s\n' "$mode_file" | awk -F'/' '{n=NF; printf "%s/%s", $(n-2), $n}' | sed 's/\.md$//')
  budget=$(jq -r --arg k "$key" '.mode_budgets[$k] // empty' "$budgets_file" 2>/dev/null)
  [ -z "$budget" ] && return 0
  words=$(wc -w < "$mode_file" | tr -d ' ')
  est=$(awk -v w="$words" 'BEGIN { printf "%d", w * 1.3 }')
  local limit
  limit=$(awk -v b="$budget" 'BEGIN { printf "%d", b * 1.1 }')
  if [ "$est" -gt "$limit" ]; then
    emit_warn "W_BUDGET_DRIFT:$mode_file:est=$est>budget*1.1=$limit | trim prose or raise budget deliberately"
  fi
}

# ---------- E_DUP_PROSE ----------
# 10-line sha1 fingerprint across all SKILL.md + modes/*.md.
check_dup_prose() {
  command -v shasum >/dev/null 2>&1 || return 0
  local tmp hashes
  tmp=$(mktemp)
  hashes=$(mktemp)
  local file
  # Walk every candidate that exists in the file tree (full set — dup detection
  # must see every file, not just staged, to spot new/existing duplicates).
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      */modes/*.md) ;;
      */SKILL.md)
        # Pre-refactor routers (no modes/ subdir yet) are exempt — dup prose in
        # the legacy SKILL.md is expected and gets resolved by the router
        # refactor itself. Post-refactor routers stay strict.
        local _agent_dir
        _agent_dir=$(dirname "$file")
        [ -d "$_agent_dir/modes" ] || continue
        ;;
      *) continue ;;
    esac
    # Build one record per 10-line window. Each record is: <file>\t<window>
    # with internal newlines of the window replaced by a sentinel (`\x1f`,
    # ASCII unit-separator, which does not appear in prose). This keeps each
    # record on a single line so the downstream `read` loop consumes one
    # record at a time instead of interpreting embedded newlines as record
    # breaks (earlier form caused E_DUP_PROSE false positives on single
    # repeated lines like `## Steps` or indented code fences).
    prose_only "$file" \
      | sed '/^[[:space:]]*$/d' \
      | awk -v f="$file" 'BEGIN { SEP = "\x1f" } { buf[NR%10]=$0; if (NR>=10) {
          s=""; for (i=1;i<=10;i++) s = s buf[(NR+i)%10] SEP;
          printf "%s\t%s\n", f, s
      } }' >> "$tmp" 2>/dev/null || true
  done < <(collect_candidates)
  # Hash each window.
  while IFS=$'\t' read -r file window; do
    [ -z "$window" ] && continue
    local h
    h=$(printf '%s' "$window" | shasum | awk '{print $1}')
    printf '%s\t%s\n' "$h" "$file" >> "$hashes"
  done < "$tmp"
  # Find hashes that appear across 2+ distinct files.
  local dup_keys
  dup_keys=$(sort -u "$hashes" | awk -F'\t' '{ c[$1]++; files[$1]=files[$1]","$2 } END { for (k in c) if (c[k]>=2) print k"\t"files[k] }')
  if [ -n "$dup_keys" ]; then
    while IFS=$'\t' read -r h files_csv; do
      files_csv="${files_csv#,}"
      emit_error "E_DUP_PROSE:$h:$files_csv | graduate to _shared/<topic>.md"
    done <<< "$dup_keys"
  fi
  rm -f "$tmp" "$hashes"
}

# ---------- E_SURFACE_REMOVED ----------
check_surface_removed() {
  local manifest="$REPO_ROOT/docs-surface.json"
  [ -f "$manifest" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local prev curr removed
  prev=$(git -C "$REPO_ROOT" show HEAD:docs-surface.json 2>/dev/null || echo '{"commands":[]}')
  if [ "$STAGED" -eq 1 ]; then
    curr=$(git -C "$REPO_ROOT" show ":docs-surface.json" 2>/dev/null || cat "$manifest")
  else
    curr=$(cat "$manifest")
  fi
  removed=$(jq -rn --argjson a "$prev" --argjson b "$curr" \
    '($a.commands // []) as $A | ($b.commands // []) as $B
     | [$A[].name] - [$B[].name] | .[]' 2>/dev/null || true)
  if [ -n "$removed" ]; then
    local cmd
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      emit_error "E_SURFACE_REMOVED:$cmd | removals are breaking, need ask-tier review"
    done <<< "$removed"
  fi
}

# ---------- Main walk ----------
main() {
  local files file
  if [ "$STAGED" -eq 1 ]; then
    files=$(collect_candidates | filter_staged)
  else
    files=$(collect_candidates)
  fi

  # Per-file checks.
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ -f "$file" ] || continue
    case "$file" in
      */_shared/*.md)
        check_frontmatter "$file" "name description type"
        ;;
      */modes/*.md)
        check_frontmatter "$file" "name description type"
        check_snapshots_decl "$file"
        check_cross_mode_load "$file"
        check_mode_size "$file"
        check_snapshot_freshness "$file"
        check_budget_drift "$file"
        ;;
      */SKILL.md)
        # Router-size only enforced if the agent has a modes/ dir (post-refactor).
        local agent_dir
        agent_dir=$(dirname "$file")
        if [ -d "$agent_dir/modes" ]; then
          check_router_size "$file"
        fi
        ;;
    esac
  done <<< "$files"

  # Cross-file checks (always full-set, regardless of --staged).
  check_dup_prose
  check_surface_removed

  printf '%d errors, %d warnings\n' "$ERRORS" "$WARNINGS" >&2
  [ "$ERRORS" -eq 0 ]
}

main
