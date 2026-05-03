#!/usr/bin/env bash
# Resolve and check Studio v2 context budgets across role, skill, and invocation dimensions.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/core/v2/context-budget/manifest.json"
FORMAT="text"
ACTION=""
ROLE=""
SKILL=""
INVOCATION=""
ESTIMATED_TOKENS=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-context-budget.sh [--manifest <path>] --validate
       scripts/v2-context-budget.sh [--manifest <path>] --resolve --role <role-or-alias> [--skill <name>] [--invocation <name>] [--estimated-tokens <n>] [--format text|json]
USAGE
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-context-budget: jq is required\n' >&2
    exit 3
  }
}

normalize_role() {
  "$REPO_ROOT/scripts/v2-role-resolve.sh" --format text "$1" 2>/dev/null
}

validate_manifest() {
  [ -r "$MANIFEST" ] || {
    printf 'v2-context-budget: manifest not readable: %s\n' "$MANIFEST" >&2
    exit 3
  }

  jq -e '
    .schema_version.name == "context-budget" and
    .kind == "studio-v2-context-budget" and
    (.defaults.max_context_tokens | type == "number") and
    (.defaults.warning_ratio < .defaults.exceeded_ratio) and
    (.roles | type == "array" and length > 0) and
    ([.roles[].role] | unique | length) == (.roles | length) and
    ([.skills[].skill] | unique | length) == (.skills | length) and
    ([.invocations[].invocation] | unique | length) == (.invocations | length)
  ' "$MANIFEST" >/dev/null || {
    printf 'v2-context-budget: invalid context-budget manifest: %s\n' "$MANIFEST" >&2
    exit 3
  }

  local role
  while IFS= read -r role; do
    [ -z "$role" ] && continue
    if ! "$REPO_ROOT/scripts/v2-role-resolve.sh" "$role" >/dev/null 2>&1; then
      printf 'v2-context-budget: unknown role in manifest: %s\n' "$role" >&2
      exit 3
    fi
  done < <(jq -r '.roles[].role' "$MANIFEST")

  local source
  while IFS= read -r source; do
    [ -z "$source" ] && continue
    if [ ! -r "$REPO_ROOT/$source" ]; then
      printf 'v2-context-budget: skill source not readable: %s\n' "$source" >&2
      exit 3
    fi
  done < <(jq -r '.skills[].source' "$MANIFEST")
}

resolve_budget() {
  [ -n "$ROLE" ] || { usage; exit 2; }
  case "$ESTIMATED_TOKENS" in
    ""|*[!0-9]*)
      [ -z "$ESTIMATED_TOKENS" ] || { usage; exit 2; }
      ;;
  esac

  local canonical_role
  canonical_role=$(normalize_role "$ROLE") || {
    printf 'v2-context-budget: unknown role or alias: %s\n' "$ROLE" >&2
    exit 1
  }

  local result
  result=$(jq -e \
    --arg role "$canonical_role" \
    --arg skill "$SKILL" \
    --arg invocation "$INVOCATION" \
    --argjson estimated "$(if [ -n "$ESTIMATED_TOKENS" ]; then printf '%s' "$ESTIMATED_TOKENS"; else printf 'null'; fi)" '
    . as $m |
    ($m.roles[] | select(.role == $role)) as $role_budget |
    (if $skill == "" then null else ($m.skills[]? | select(.skill == $skill)) end) as $skill_budget |
    (if $invocation == "" then null else ($m.invocations[]? | select(.invocation == $invocation)) end) as $invocation_budget |
    if $skill != "" and $skill_budget == null and $m.resolution.unknown_skill_policy == "reject" then
      error("unknown skill: " + $skill)
    elif $invocation != "" and $invocation_budget == null and $m.resolution.unknown_invocation_policy == "reject" then
      error("unknown invocation: " + $invocation)
    else
      [
        {"dimension": "default", "name": "default", "max_context_tokens": $m.defaults.max_context_tokens},
        {"dimension": "role", "name": $role, "max_context_tokens": $role_budget.max_context_tokens},
        (if $skill_budget == null then empty else {"dimension": "skill", "name": $skill, "max_context_tokens": $skill_budget.max_context_tokens} end),
        (if $invocation_budget == null then empty else {"dimension": "invocation", "name": $invocation, "max_context_tokens": $invocation_budget.max_context_tokens} end)
      ] as $matches |
      ($matches | min_by(.max_context_tokens)) as $effective |
      (if $estimated == null then null else ($estimated / $effective.max_context_tokens) end) as $ratio |
      (if $estimated == null then "unmeasured"
       elif $ratio >= $m.defaults.exceeded_ratio then "exceeded"
       elif $ratio >= $m.defaults.warning_ratio then "warning"
       else "ok" end) as $status |
      {
        schema_version: {"name": "context-budget-resolution", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
        role: $role,
        skill: (if $skill == "" then null else $skill end),
        invocation: (if $invocation == "" then null else $invocation end),
        effective_budget_tokens: $effective.max_context_tokens,
        limiting_dimension: $effective.dimension,
        limiting_name: $effective.name,
        matched_budgets: $matches,
        estimated_tokens: $estimated,
        ratio: (if $ratio == null then null else (($ratio * 1000 | round) / 1000) end),
        status: $status,
        telemetry_event: (if $status == "exceeded" then $m.telemetry.exceeded_event else $m.telemetry.resolved_event end)
      }
    end
  ' "$MANIFEST") || {
    printf 'v2-context-budget: failed to resolve budget\n' >&2
    exit 1
  }

  if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$result" | jq -r '
      "role=\(.role) skill=\(.skill // "none") invocation=\(.invocation // "none") budget=\(.effective_budget_tokens) limiting=\(.limiting_dimension):\(.limiting_name) status=\(.status) ratio=\(.ratio // "n/a") event=\(.telemetry_event)"
    '
  fi
}

require_jq

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MANIFEST="$2"
      shift 2
      ;;
    --validate)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="validate"
      shift
      ;;
    --resolve)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="resolve"
      shift
      ;;
    --role)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ROLE="$2"
      shift 2
      ;;
    --skill)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SKILL="$2"
      shift 2
      ;;
    --invocation)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      INVOCATION="$2"
      shift 2
      ;;
    --estimated-tokens)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ESTIMATED_TOKENS="$2"
      shift 2
      ;;
    --format)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      FORMAT="$2"
      case "$FORMAT" in
        text|json) ;;
        *) usage; exit 2 ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$ACTION" in
  validate)
    validate_manifest
    printf 'v2-context-budget: ok\n' >&2
    ;;
  resolve)
    validate_manifest
    resolve_budget
    ;;
  *)
    usage
    exit 2
    ;;
esac
