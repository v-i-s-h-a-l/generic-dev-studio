#!/usr/bin/env bash
# capability-manifest.sh — regenerates _shared/schemas/capability-manifest.json
# from every agent's SKILL.md + modes/*.md frontmatter. Lists each agent with
# its modes, per-mode reads/writes/snapshots/dry_run/budget. Router-level
# reads/writes are the union of its modes (auto-synthesized, never
# hand-maintained — see _shared/patterns/capability-manifest.md).
#
# Usage:
#   scripts/capability-manifest.sh            # prints manifest to stdout
#   scripts/capability-manifest.sh --regen    # writes to the canonical path
#   scripts/capability-manifest.sh --validate # diff against committed; exit 1 on drift

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/_shared/schemas/capability-manifest.json"

MODE="${1:-stdout}"

# Extract frontmatter (lines between the two --- fences). Empty if either
# fence is missing.
extract_fm() {
  awk 'NR==1 && $0=="---" {flag=1; next}
       flag && $0=="---" {exit}
       flag {print}' "$1"
}

# Pull a single scalar key (e.g. `name: foo`) from frontmatter.
fm_scalar() {
  local file="$1" key="$2"
  extract_fm "$file" | awk -v k="$key" '
    match($0, "^" k ":[[:space:]]*") {
      v = substr($0, RLENGTH+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  '
}

# Pull a YAML list (inline `reads: [a, b]` or block form) as newline-separated
# items. Empty output means no list / empty list.
fm_list() {
  local file="$1" key="$2"
  extract_fm "$file" | awk -v k="$key" '
    BEGIN { state=0 }
    state==0 && match($0, "^" k ":[[:space:]]*\\[") {
      line = substr($0, RLENGTH+1)
      sub(/\].*$/, "", line)
      n = split(line, parts, ",")
      for (i=1; i<=n; i++) {
        s = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        gsub(/^"|"$/, "", s)
        if (s != "") print s
      }
      exit
    }
    state==0 && match($0, "^" k ":[[:space:]]*$") { state=1; next }
    state==1 {
      if (match($0, "^[[:space:]]+-[[:space:]]*")) {
        v = substr($0, RLENGTH+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        print v
      } else if (match($0, "^[^[:space:]]")) {
        exit
      }
    }
  '
}

# JSON string escaping: backslash, double-quote, newline, tab, CR.
json_str() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Emit a JSON array of strings from a newline-separated string argument.
json_list_from_string() {
  local list="$1" first=1 item
  printf '['
  if [ -n "$list" ]; then
    while IFS= read -r item; do
      [ -z "$item" ] && continue
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ', '
      fi
      printf '"%s"' "$(json_str "$item")"
    done <<< "$list"
  fi
  printf ']'
}

# Compute union of reads/writes across all modes in an agent dir (router-level
# surface per patterns/capability-manifest.md). Newline-separated, unique.
union_surface() {
  local agent_dir="$1" key="$2" f
  {
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
      fm_list "$f" "$key"
    done < <(find "$agent_dir/modes" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
  } | sort -u | sed '/^$/d'
}

emit_manifest() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{\n'
  printf '  "schema_version": {\n'
  printf '    "name": "capability-manifest",\n'
  printf '    "version": "1.0.0",\n'
  printf '    "min_reader": "1.0.0",\n'
  printf '    "deprecated_at": null\n'
  printf '  },\n'
  printf '  "generated_at": "%s",\n' "$now"
  printf '  "agents": [\n'

  local first_agent=1
  local skill_md agent_dir agent_name router_desc
  local reads_union writes_union
  while IFS= read -r skill_md; do
    [ -z "$skill_md" ] && continue
    agent_dir=$(dirname "$skill_md")
    agent_name=$(basename "$agent_dir")
    case "$agent_name" in
      _shared|commands|scripts|.githooks) continue ;;
    esac
    [ -d "$agent_dir/modes" ] || continue
    router_desc=$(fm_scalar "$skill_md" description)
    reads_union=$(union_surface "$agent_dir" reads)
    writes_union=$(union_surface "$agent_dir" writes)

    if [ "$first_agent" -eq 1 ]; then
      first_agent=0
    else
      printf ',\n'
    fi

    printf '    {\n'
    printf '      "name": "%s",\n' "$(json_str "$agent_name")"
    printf '      "router": "%s",\n' "$(json_str "${skill_md#"$REPO_ROOT/"}")"
    printf '      "description": "%s",\n' "$(json_str "$router_desc")"
    printf '      "reads": %s,\n' "$(json_list_from_string "$reads_union")"
    printf '      "writes": %s,\n' "$(json_list_from_string "$writes_union")"
    printf '      "modes": [\n'

    local first_mode=1
    local mode_file mode_name mode_desc mode_type reads_list writes_list snaps_list budget dry_run
    while IFS= read -r mode_file; do
      [ -z "$mode_file" ] && continue
      [ -f "$mode_file" ] || continue
      mode_name=$(basename "$mode_file" .md)
      mode_desc=$(fm_scalar "$mode_file" description)
      mode_type=$(fm_scalar "$mode_file" type)
      reads_list=$(fm_list "$mode_file" reads)
      writes_list=$(fm_list "$mode_file" writes)
      snaps_list=$(fm_list "$mode_file" snapshots)
      budget=$(fm_scalar "$mode_file" budget_tokens)
      dry_run=$(fm_scalar "$mode_file" dry_run)
      [ -z "$dry_run" ] && dry_run=false

      if [ "$first_mode" -eq 1 ]; then
        first_mode=0
      else
        printf ',\n'
      fi
      printf '        {\n'
      printf '          "name": "%s",\n' "$(json_str "$mode_name")"
      printf '          "path": "%s",\n' "$(json_str "${mode_file#"$REPO_ROOT/"}")"
      printf '          "type": "%s",\n' "$(json_str "$mode_type")"
      printf '          "description": "%s",\n' "$(json_str "$mode_desc")"
      printf '          "reads": %s,\n' "$(json_list_from_string "$reads_list")"
      printf '          "writes": %s,\n' "$(json_list_from_string "$writes_list")"
      printf '          "snapshots": %s,\n' "$(json_list_from_string "$snaps_list")"
      printf '          "dry_run": %s,\n' "$dry_run"
      if [ -n "$budget" ]; then
        printf '          "budget_tokens": %s\n' "$budget"
      else
        printf '          "budget_tokens": null\n'
      fi
      printf '        }'
    done < <(find "$agent_dir/modes" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

    printf '\n      ]\n'
    printf '    }'
  done < <(
    {
      find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null
      find "$REPO_ROOT/.claude/skills" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null
    } | sort -u
  )

  printf '\n  ]\n'
  printf '}\n'
}

case "$MODE" in
  --regen)
    tmp=$(mktemp)
    emit_manifest > "$tmp"
    mkdir -p "$(dirname "$MANIFEST")"
    mv "$tmp" "$MANIFEST"
    printf 'wrote %s\n' "$MANIFEST"
    ;;
  --validate)
    # Regenerate to a scratch file, diff against committed ignoring the
    # generated_at timestamp line (naturally changes every run). Intended for
    # pre-commit — the hook auto-stages on drift (matching the docs-surface.json
    # pattern).
    scratch=$(mktemp)
    emit_manifest > "$scratch"
    if [ ! -f "$MANIFEST" ]; then
      printf 'validate: manifest missing at %s\n' "$MANIFEST" >&2
      rm -f "$scratch"
      exit 1
    fi
    # Strip the generated_at line from both sides before comparing.
    comm_a=$(mktemp); comm_b=$(mktemp)
    grep -v '"generated_at":' "$MANIFEST" > "$comm_a"
    grep -v '"generated_at":' "$scratch" > "$comm_b"
    if ! diff -u "$comm_a" "$comm_b" >/dev/null 2>&1; then
      printf 'validate: manifest drift detected vs committed. Run: scripts/capability-manifest.sh --regen\n' >&2
      diff -u "$comm_a" "$comm_b" | head -30 >&2 || true
      rm -f "$scratch" "$comm_a" "$comm_b"
      exit 1
    fi
    rm -f "$scratch" "$comm_a" "$comm_b"
    ;;
  stdout|"")
    emit_manifest
    ;;
  *)
    printf 'usage: capability-manifest.sh [--regen | --validate]\n' >&2
    exit 2
    ;;
esac
