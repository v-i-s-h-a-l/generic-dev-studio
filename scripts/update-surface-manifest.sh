#!/usr/bin/env bash
# update-surface-manifest.sh — regenerates docs-surface.json from the current
# command-surface state. Run by the pre-commit hook before the linter; the
# linter's E_SURFACE_REMOVED check diffs HEAD:docs-surface.json against the
# regenerated file to catch removals.
#
# Sources:
#   commands/*.md             → globally-symlinked slash commands
#   .claude/commands/*.md     → project-scoped slash commands (only active
#                               when Claude Code runs inside this repo)
#   <skill>/SKILL.md          → agent routers (single entry per agent, plus
#                               any dispatch-table entries if present)
#   <skill>/modes/*.md        → agent sub-mode entries

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT="$REPO_ROOT/docs-surface.json"
TMP=$(mktemp)

frontmatter_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_fm=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm==1 && $0=="---" { exit }
    in_fm==1 {
      if (match($0, "^" k ":[[:space:]]*")) {
        v = substr($0, RLENGTH+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }
  ' "$file"
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
  printf '{\n'
  printf '  "generated_at": "%s",\n' "$now"
  printf '  "schema": 1,\n'
  printf '  "commands": [\n'

  first=1
  emit() {
    local json="$1"
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    %s' "$json"
  }

  json_str() {
    # Minimal JSON string escaping: backslash, double-quote, newline.
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
  }

  # commands/*.md  — globally-symlinked commands
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    name=$(basename "$f" .md)
    desc=$(frontmatter_value "$f" description)
    rel="${f#"$REPO_ROOT/"}"
    emit "$(printf '{"name": "%s", "source": "%s", "description": "%s", "agent": null, "scope": "global"}' \
      "$(json_str "$name")" "$(json_str "$rel")" "$(json_str "$desc")")"
  done < <(find "$REPO_ROOT/commands" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

  # .claude/commands/*.md — project-scoped commands (active only in this repo)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    name=$(basename "$f" .md)
    desc=$(frontmatter_value "$f" description)
    rel="${f#"$REPO_ROOT/"}"
    emit "$(printf '{"name": "%s", "source": "%s", "description": "%s", "agent": null, "scope": "project"}' \
      "$(json_str "$name")" "$(json_str "$rel")" "$(json_str "$desc")")"
  done < <(find "$REPO_ROOT/.claude/commands" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

  # Agent routers (SKILL.md)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    agent=$(basename "$(dirname "$f")")
    case "$agent" in
      _shared|commands|scripts|.githooks) continue ;;
    esac
    desc=$(frontmatter_value "$f" description)
    rel="${f#"$REPO_ROOT/"}"
    emit "$(printf '{"name": "%s", "source": "%s", "agent": "%s", "description": "%s"}' \
      "$(json_str "$agent")" "$(json_str "$rel")" "$(json_str "$agent")" "$(json_str "$desc")")"
  done < <(find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null | sort)

  # Mode packs
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    mode=$(basename "$f" .md)
    agent=$(basename "$(dirname "$(dirname "$f")")")
    desc=$(frontmatter_value "$f" description)
    rel="${f#"$REPO_ROOT/"}"
    emit "$(printf '{"name": "%s.%s", "source": "%s", "agent": "%s", "mode": "%s", "description": "%s"}' \
      "$(json_str "$agent")" "$(json_str "$mode")" "$(json_str "$rel")" \
      "$(json_str "$agent")" "$(json_str "$mode")" "$(json_str "$desc")")"
  done < <(find "$REPO_ROOT" -mindepth 3 -maxdepth 3 -type f -path '*/modes/*.md' 2>/dev/null | sort)

  printf '\n  ]\n}\n'
} > "$TMP"

mv "$TMP" "$OUT"
printf 'wrote %s\n' "$OUT"
