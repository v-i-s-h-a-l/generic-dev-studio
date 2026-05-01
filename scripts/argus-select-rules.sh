#!/usr/bin/env bash
# argus-select-rules.sh — apply Argus rule-pack frontmatter to a diff classifier JSON.

set -u
umask 022

CLASSIFIER_JSON="${1:?usage: argus-select-rules.sh <classifier-json> [rules-dir]}"
RULES_DIR="${2:-argus/rules}"

[ -d "$RULES_DIR" ] || {
  printf 'argus-select-rules.sh: rules dir not found: %s\n' "$RULES_DIR" >&2
  exit 2
}

if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$CLASSIFIER_JSON" | jq empty >/dev/null 2>&1; then
    printf 'argus-select-rules.sh: classifier JSON is invalid\n' >&2
    exit 2
  fi
else
  printf 'argus-select-rules.sh: jq is required\n' >&2
  exit 2
fi

json_bool() {
  key="$1"
  printf '%s' "$CLASSIFIER_JSON" | jq -er --arg key "$key" '.[$key] == true' >/dev/null 2>&1
}

frontmatter_value() {
  file="$1"
  key="$2"
  awk -v key="$key" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub("^[^:]+:[[:space:]]*", "")
      print
      exit
    }
  ' "$file"
}

array_items() {
  value="$1"
  printf '%s\n' "$value" \
    | sed 's/#.*$//; s/^\[//; s/\]$//' \
    | tr ',' '\n' \
    | sed 's/[[:space:]]//g; /^$/d'
}

matches_list() {
  mode="$1"
  list="$2"

  case "$mode" in
    any_of)
      [ -z "$list" ] && return 0
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        if json_bool "$key"; then
          return 0
        fi
      done <<EOF
$list
EOF
      return 1
      ;;
    all_of)
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! json_bool "$key"; then
          return 1
        fi
      done <<EOF
$list
EOF
      return 0
      ;;
    none_of)
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        if json_bool "$key"; then
          return 1
        fi
      done <<EOF
$list
EOF
      return 0
      ;;
  esac
}

load_tmp=$(mktemp -t argus-rules-load.XXXXXX) || exit 2
skip_tmp=$(mktemp -t argus-rules-skip.XXXXXX) || exit 2
trap 'rm -f "$load_tmp" "$skip_tmp"' EXIT

for file in "$RULES_DIR"/*.md; do
  [ -e "$file" ] || continue
  pack=$(basename "$file" .md)

  any_list=$(array_items "$(frontmatter_value "$file" "  any_of")")
  all_list=$(array_items "$(frontmatter_value "$file" "  all_of")")
  none_list=$(array_items "$(frontmatter_value "$file" "  none_of")")

  if matches_list any_of "$any_list" \
    && matches_list all_of "$all_list" \
    && matches_list none_of "$none_list"; then
    printf '%s\n' "$pack" >> "$load_tmp"
  else
    printf '%s\n' "$pack" >> "$skip_tmp"
  fi
done

jq -n \
  --argjson classifier "$CLASSIFIER_JSON" \
  --rawfile load "$load_tmp" \
  --rawfile skipped "$skip_tmp" \
  '{
    classifier: $classifier,
    load: ($load | split("\n") | map(select(length > 0))),
    skipped: ($skipped | split("\n") | map(select(length > 0)))
  }'
