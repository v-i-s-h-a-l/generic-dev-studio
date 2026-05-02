#!/usr/bin/env bash
# resolve-reviewer-model.sh — select PR reviewer model from shared policy.
#
# Usage:
#   scripts/resolve-reviewer-model.sh --review-host <host> [--implementation-host <host>]
#       [--role reviewer.heavyweight] [--allow-same-family]

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CATALOG="$REPO_ROOT/_shared/schemas/model-catalog.yaml"
POLICY="$REPO_ROOT/_shared/rules/model-policy.yaml"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

REVIEW_HOST=""
IMPLEMENTATION_HOST="${STUDIO_PARENT_HOST:-${STUDIO_HOST:-unknown}}"
ROLE="reviewer.heavyweight"
ALLOW_SAME_FAMILY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --implementation-host) IMPLEMENTATION_HOST="${2:?--implementation-host requires a value}"; shift 2 ;;
    --role) ROLE="${2:?--role requires a value}"; shift 2 ;;
    --allow-same-family) ALLOW_SAME_FAMILY=1; shift ;;
    -h|--help) usage ;;
    *) printf 'resolve-reviewer-model: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$REVIEW_HOST" ] || usage
[ -f "$CATALOG" ] || { printf 'resolve-reviewer-model: missing catalog: %s\n' "$CATALOG" >&2; exit 1; }
[ -f "$POLICY" ] || { printf 'resolve-reviewer-model: missing policy: %s\n' "$POLICY" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'resolve-reviewer-model: yq is required\n' >&2; exit 1; }

shell_assign() {
  local key="$1" value="${2:-}"
  printf '%s=%q\n' "$key" "$value"
}

adapter_family() {
  local host="$1" family
  family=$(HOST_NAME="$host" yq -r '
    (.adapter_profiles[strenv(HOST_NAME)].provider_family // "") as $direct
    | if $direct != "" then $direct
      else ((.provider_families | to_entries | map(select((.value.adapters // []) | contains([strenv(HOST_NAME)])) | .key) | .[0]) // "")
      end
  ' "$CATALOG" 2>/dev/null)
  if [ -n "$family" ] && [ "$family" != "null" ]; then
    printf '%s\n' "$family"
    return 0
  fi
  case "$host" in
    codex*|*codex*) printf 'openai\n' ;;
    claude-code|claude|claude-*|*claude*) printf 'anthropic\n' ;;
    unknown|"") printf 'unknown\n' ;;
    *) printf '%s\n' "$host" ;;
  esac
}

role_exists=$(ROLE_NAME="$ROLE" yq -r '.roles[strenv(ROLE_NAME)] != null' "$POLICY" 2>/dev/null)
[ "$role_exists" = "true" ] || {
  printf 'resolve-reviewer-model: unknown role: %s\n' "$ROLE" >&2
  exit 2
}

review_family=$(adapter_family "$REVIEW_HOST")
implementation_family=$(adapter_family "$IMPLEMENTATION_HOST")
if [ "$ALLOW_SAME_FAMILY" -eq 0 ] \
    && [ "$implementation_family" != "unknown" ] \
    && [ "$review_family" = "$implementation_family" ]; then
  printf 'resolve-reviewer-model: reviewer family %s matches implementation family %s for host %s\n' "$review_family" "$implementation_family" "$REVIEW_HOST" >&2
  exit 3
fi

selected_key=""
while IFS= read -r key; do
  [ -n "$key" ] && [ "$key" != "null" ] || continue
  if MODEL_KEY="$key" REVIEW_FAMILY="$review_family" REVIEW_HOST_NAME="$REVIEW_HOST" yq -e '
      .models[strenv(MODEL_KEY)] != null
      and .models[strenv(MODEL_KEY)].provider_family == strenv(REVIEW_FAMILY)
      and ((.models[strenv(MODEL_KEY)].role_suitability // []) | contains(["reviewer"]))
      and ((.models[strenv(MODEL_KEY)].adapter_profiles // []) | contains([strenv(REVIEW_HOST_NAME)]))
    ' "$CATALOG" >/dev/null 2>&1; then
    selected_key="$key"
    break
  fi
done < <(ROLE_NAME="$ROLE" yq -r '.roles[strenv(ROLE_NAME)].model_preferences[]?' "$POLICY" 2>/dev/null)

[ -n "$selected_key" ] || {
  printf 'resolve-reviewer-model: no %s model found for review_host=%s provider_family=%s\n' "$ROLE" "$REVIEW_HOST" "$review_family" >&2
  exit 4
}

model_id=$(MODEL_KEY="$selected_key" yq -r '.models[strenv(MODEL_KEY)].id' "$CATALOG")
model_effort=$(MODEL_KEY="$selected_key" yq -r '.models[strenv(MODEL_KEY)].reasoning_effort.default // ""' "$CATALOG")
role_effort=$(ROLE_NAME="$ROLE" yq -r '.roles[strenv(ROLE_NAME)].reasoning_effort // ""' "$POLICY")
policy_effort=$(yq -r '.roles."reviewer.reasoning_effort".default // "high"' "$POLICY")
effort="$model_effort"
[ -n "$effort" ] && [ "$effort" != "null" ] || effort="$role_effort"
[ -n "$effort" ] && [ "$effort" != "null" ] || effort="$policy_effort"
[ -n "$effort" ] && [ "$effort" != "null" ] || effort="high"
source_url=$(MODEL_KEY="$selected_key" yq -r '.models[strenv(MODEL_KEY)].source.url // ""' "$CATALOG")
last_verified_at=$(MODEL_KEY="$selected_key" yq -r '.models[strenv(MODEL_KEY)].source.last_verified_at // ""' "$CATALOG")

shell_assign REVIEWER_MODEL_KEY "$selected_key"
shell_assign REVIEWER_MODEL_ID "$model_id"
shell_assign REVIEWER_MODEL_PROVIDER_FAMILY "$review_family"
shell_assign REVIEWER_IMPLEMENTATION_PROVIDER_FAMILY "$implementation_family"
shell_assign REVIEWER_MODEL_REASONING_EFFORT "$effort"
shell_assign REVIEWER_MODEL_ROLE "$ROLE"
shell_assign REVIEWER_MODEL_SOURCE_URL "$source_url"
shell_assign REVIEWER_MODEL_LAST_VERIFIED_AT "$last_verified_at"
