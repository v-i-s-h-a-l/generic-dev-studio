#!/usr/bin/env bash
# validate-schema.sh — reader-side schema_version check for YAML artifacts.
#
# Usage:
#   scripts/validate-schema.sh <artifact-path>
#   scripts/validate-schema.sh <artifact-path> --reader-table=<path>
#
# Reads the artifact's schema_version object, compares against the reader
# version table (default: _shared/schemas/reader-versions.json), and:
#   - exits 0 if the artifact is acceptable (including "reader newer than
#     artifact" with a warn-tier `schema_version_gap` emission);
#   - exits 1 if the reader is too old (artifact.min_reader > reader_max)
#     or the artifact version is past `deprecated_at`.
#
# Per `_shared/contracts/schema-version.md` §Rules: never silently degrade.
# Mismatches emit events via lib-paths' `append_event`.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

ARTIFACT="${1:?usage: validate-schema.sh <artifact-path> [--reader-table=<path>]}"
READER_TABLE="$REPO_ROOT/_shared/schemas/reader-versions.json"

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --reader-table=*) READER_TABLE="${1#--reader-table=}"; shift ;;
    --reader-table)   READER_TABLE="${2:?--reader-table requires path}"; shift 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$ARTIFACT" ]; then
  printf 'error: artifact not found: %s\n' "$ARTIFACT" >&2
  exit 2
fi
if [ ! -f "$READER_TABLE" ]; then
  printf 'error: reader-table not found: %s\n' "$READER_TABLE" >&2
  exit 2
fi

# Extract schema_version fields. Supports both inline
#   `schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}`
# and block form
#   `schema_version:\n  name: task\n  version: 1.0.0\n  ...`
extract_field() {
  local artifact="$1" key="$2"
  # Try inline form first.
  local line v
  line=$(grep -E '^schema_version:[[:space:]]*\{' "$artifact" 2>/dev/null | head -n 1)
  if [ -n "$line" ]; then
    if [[ "$line" =~ ${key}:[[:space:]]*\"?([^,}\"]+)\"? ]]; then
      v="${BASH_REMATCH[1]}"
      # Trim whitespace.
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      printf '%s' "$v"
      return 0
    fi
  fi
  # Block form.
  awk -v k="$key" '
    /^schema_version:[[:space:]]*$/ { flag=1; next }
    flag && /^[^[:space:]]/ { exit }
    flag && $0 ~ "^[[:space:]]+" k ":[[:space:]]*" {
      v = $0
      sub("^[[:space:]]+" k ":[[:space:]]*", "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      print v
      exit
    }
  ' "$artifact"
}

NAME=$(extract_field "$ARTIFACT" name)
VERSION=$(extract_field "$ARTIFACT" version)
MIN_READER=$(extract_field "$ARTIFACT" min_reader)
DEPRECATED_AT=$(extract_field "$ARTIFACT" deprecated_at)

if [ -z "$NAME" ] || [ -z "$VERSION" ] || [ -z "$MIN_READER" ]; then
  printf 'E_SCHEMA_REQUIRED_MISSING:%s:name=%s version=%s min_reader=%s\n' \
    "$ARTIFACT" "$NAME" "$VERSION" "$MIN_READER" >&2
  exit 1
fi

# Reader's version range for this schema. Table shape:
#   {"task": {"max_known": "1.0.0", "min_acceptable": "1.0.0"}, …}
if ! command -v jq >/dev/null 2>&1; then
  # Degrade gracefully: accept if we can't read the table. Warn on stderr.
  printf 'warn: jq not installed — skipping full schema validation\n' >&2
  exit 0
fi

READER_MAX=$(jq -r --arg name "$NAME" '.[$name].max_known // empty' "$READER_TABLE" 2>/dev/null)
READER_MIN=$(jq -r --arg name "$NAME" '.[$name].min_acceptable // empty' "$READER_TABLE" 2>/dev/null)

if [ -z "$READER_MAX" ] || [ -z "$READER_MIN" ]; then
  printf 'E_SCHEMA_UNKNOWN:%s:name=%s | reader table has no entry for this schema\n' \
    "$ARTIFACT" "$NAME" >&2
  exit 1
fi

# SemVer compare — returns 0 if $1 >= $2. Splits on dots; compares
# field-by-field as integers.
semver_ge() {
  local a="$1" b="$2"
  local IFS=.
  local a_arr=($a) b_arr=($b)
  local i
  for i in 0 1 2; do
    local av="${a_arr[$i]:-0}" bv="${b_arr[$i]:-0}"
    if [ "$av" -gt "$bv" ]; then return 0; fi
    if [ "$av" -lt "$bv" ]; then return 1; fi
  done
  return 0
}

# Reader too old: reader_max < artifact.min_reader → block.
if ! semver_ge "$READER_MAX" "$MIN_READER"; then
  append_event validator schema_read_rejected "" \
    "{\"reason\":\"reader_too_old\",\"artifact\":\"$ARTIFACT\",\"schema\":\"$NAME@$VERSION\",\"reader_max\":\"$READER_MAX\",\"min_reader\":\"$MIN_READER\"}" 2>/dev/null || true
  printf 'E_SCHEMA_READER_TOO_OLD:%s:%s@%s (reader_max=%s < min_reader=%s)\n' \
    "$ARTIFACT" "$NAME" "$VERSION" "$READER_MAX" "$MIN_READER" >&2
  exit 1
fi

# Deprecation check. If deprecated_at is non-null and in the past → block.
if [ -n "$DEPRECATED_AT" ] && [ "$DEPRECATED_AT" != "null" ]; then
  # Compare lexically — RFC3339 timestamps sort correctly as strings.
  local_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$DEPRECATED_AT" \< "$local_now" ]; then
    append_event validator schema_read_rejected "" \
      "{\"reason\":\"deprecated_in_past\",\"artifact\":\"$ARTIFACT\",\"schema\":\"$NAME@$VERSION\",\"deprecated_at\":\"$DEPRECATED_AT\"}" 2>/dev/null || true
    printf 'E_SCHEMA_DEPRECATED:%s:%s@%s (deprecated_at=%s)\n' \
      "$ARTIFACT" "$NAME" "$VERSION" "$DEPRECATED_AT" >&2
    exit 1
  fi
fi

# Reader newer than artifact but not crossed deprecated_at → warn tier.
if ! semver_ge "$VERSION" "$READER_MAX"; then
  # Reader version > artifact version. Emit schema_version_gap and exit 0.
  # This is the "gracefully forward-compatible" path.
  append_event validator schema_version_gap "" \
    "{\"artifact\":\"$ARTIFACT\",\"schema\":\"$NAME@$VERSION\",\"reader_max\":\"$READER_MAX\"}" 2>/dev/null || true
fi

exit 0
