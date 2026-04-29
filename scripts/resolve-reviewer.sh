#!/usr/bin/env bash
# resolve-reviewer.sh — pick a reviewer host + model + reasoning effort.
#
# Usage:
#   scripts/resolve-reviewer.sh [--impl-host <h>] [--role <role>] [--seed <n>]
#
# Reads:
#   _shared/schemas/model-catalog.yaml   (which models exist per family)
#   _shared/rules/model-policy.yaml      (role -> tier, independence rules)
#   hosts/registry.yaml                  (host -> provider_family)
#   <reviewer_hosts>/capabilities.yaml   (reviewer_profile flag)
#
# Selection priority:
#   1. Reviewer host whose family != impl host's family, at the role's tier.
#   2. Same-family reviewer with the tier escalated one notch
#      (medium -> high -> max -> max). Effort is lifted to the collision floor.
#   3. Hard block (exit 3, marker line) when no reviewer host is eligible.
#
# Output (stdout, KEY=VALUE on success):
#   STUDIO_REVIEWER_HOST=<host>
#   STUDIO_REVIEWER_MODEL=<model id from the catalog>
#   STUDIO_REVIEWER_REASONING_EFFORT=<effort or "">
#   STUDIO_REVIEWER_TIER=<tier the model was picked at>
#   STUDIO_REVIEWER_FAMILY_COLLISION=true|false
#   STUDIO_REVIEWER_ESCALATED=true|false
#   STUDIO_REVIEWER_IMPL_HOST=<impl host or "unknown">
#   STUDIO_REVIEWER_IMPL_FAMILY=<impl family or "">
#
# On hard block (exit 3):
#   STUDIO_REVIEWER_RESOLUTION=blocked
#   STUDIO_REVIEWER_REASON=<reason slug>
#
# Zero LLM tokens are spent on selection; this is pure shell+yq.

set -u
umask 022

usage() {
  printf 'usage: resolve-reviewer.sh [--impl-host <h>] [--role <role>] [--seed <n>]\n' >&2
  exit 2
}

IMPL_HOST="${STUDIO_IMPL_HOST:-}"
ROLE="reviewer.heavyweight"
SEED=""
FORCE_HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --impl-host)  IMPL_HOST="${2:?--impl-host requires a value}"; shift 2 ;;
    --role)       ROLE="${2:?--role requires a value}"; shift 2 ;;
    --seed)       SEED="${2:?--seed requires a value}"; shift 2 ;;
    --force-host) FORCE_HOST="${2:?--force-host requires a value}"; shift 2 ;;
    -h|--help)    usage ;;
    *) printf 'resolve-reviewer: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-model-policy.sh
. "$SCRIPT_DIR/lib-model-policy.sh"

: "${STUDIO_MODEL_CATALOG_FILE:=$REPO_ROOT/_shared/schemas/model-catalog.yaml}"
: "${STUDIO_MODEL_POLICY_FILE:=$REPO_ROOT/_shared/rules/model-policy.yaml}"
: "${STUDIO_HOSTS_REGISTRY_FILE:=$REPO_ROOT/hosts/registry.yaml}"
export STUDIO_MODEL_CATALOG_FILE STUDIO_MODEL_POLICY_FILE STUDIO_HOSTS_REGISTRY_FILE

# Optional override path for tests; default is the production eligibility script.
: "${STUDIO_REVIEWER_ELIGIBILITY_SCRIPT:=$SCRIPT_DIR/pr-reviewer-eligibility.sh}"

mp_require_files || exit 2

emit_blocked() {
  printf 'STUDIO_REVIEWER_RESOLUTION=blocked\n'
  printf 'STUDIO_REVIEWER_REASON=%s\n' "$1"
  printf 'STUDIO_REVIEWER_IMPL_HOST=%s\n' "${IMPL_HOST:-unknown}"
  printf 'STUDIO_REVIEWER_IMPL_FAMILY=%s\n' "${IMPL_FAMILY:-}"
  exit 3
}

IMPL_FAMILY=""
if [ -n "$IMPL_HOST" ] && [ "$IMPL_HOST" != "unknown" ]; then
  IMPL_FAMILY=$(mp_provider_family_for_host "$IMPL_HOST")
fi

# 1. Walk reviewer-profile hosts in the registry, gating each through the
# eligibility script so we only consider hosts that can actually run. When
# --force-host is supplied, we still gate that single host through eligibility
# but skip the independence partition entirely.
ELIGIBLE_HOSTS=()
if [ -n "$FORCE_HOST" ]; then
  manifest=$(resolve_capabilities_manifest "$FORCE_HOST" "$REPO_ROOT" 2>/dev/null || true)
  [ -n "$manifest" ] && [ -f "$manifest" ] || emit_blocked forced_host_missing_manifest
  reviewer_profile=$(yq -r '.reviewer_profile // false' "$manifest" 2>/dev/null)
  [ "$reviewer_profile" = "true" ] || emit_blocked forced_host_not_reviewer_profile
  "$STUDIO_REVIEWER_ELIGIBILITY_SCRIPT" "$FORCE_HOST" >/dev/null 2>&1 \
    || emit_blocked forced_host_not_eligible
  ELIGIBLE_HOSTS=("$FORCE_HOST")
else
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT" 2>/dev/null || true)
    [ -n "$manifest" ] && [ -f "$manifest" ] || continue
    reviewer_profile=$(yq -r '.reviewer_profile // false' "$manifest" 2>/dev/null)
    [ "$reviewer_profile" = "true" ] || continue
    if "$STUDIO_REVIEWER_ELIGIBILITY_SCRIPT" "$host" >/dev/null 2>&1; then
      ELIGIBLE_HOSTS+=("$host")
    fi
  done < <(mp_reviewer_hosts_in_registry)
fi

[ "${#ELIGIBLE_HOSTS[@]}" -gt 0 ] || emit_blocked no_eligible_reviewer_host

# 2. Partition eligible hosts by family vs impl family.
# --force-host bypasses independence enforcement: the user has named the
# reviewer explicitly. We still pick a model at the role's nominal tier.
DIFFERENT_FAMILY=()
SAME_FAMILY=()
if [ -n "$FORCE_HOST" ]; then
  DIFFERENT_FAMILY=("$FORCE_HOST")
else
  for host in "${ELIGIBLE_HOSTS[@]}"; do
    fam=$(mp_provider_family_for_host "$host")
    if [ -n "$IMPL_FAMILY" ] && [ "$fam" = "$IMPL_FAMILY" ]; then
      SAME_FAMILY+=("$host")
    else
      DIFFERENT_FAMILY+=("$host")
    fi
  done
fi

ROLE_TIER=$(mp_role_tier "$ROLE")
[ -n "$ROLE_TIER" ] || emit_blocked unknown_role
ROLE_EFFORT=$(mp_role_effort "$ROLE")

pick_index() {
  local count="$1"
  if [ -n "$SEED" ]; then
    printf '%s' "$(( SEED % count ))"
  else
    printf '0'
  fi
}

resolve_against_pool() {
  local pool_name="$1"
  local tier="$2"
  local role="$3"
  local effort="$4"
  shift 4
  local pool=("$@")
  local count="${#pool[@]}"
  [ "$count" -gt 0 ] || return 1
  local idx
  idx=$(pick_index "$count")
  local host="${pool[$idx]}"
  local fam
  fam=$(mp_provider_family_for_host "$host")
  local model
  model=$(mp_pick_model "$fam" "$tier" "$role")
  if [ -z "$model" ] || [ "$model" = "null" ]; then
    return 1
  fi
  local supports_effort
  supports_effort=$(mp_family_supports_effort "$fam")
  local emit_effort=""
  [ "$supports_effort" = "true" ] && emit_effort="$effort"
  # Pipe-separated because bash `read` with IFS=$'\t' collapses adjacent
  # empty fields (whitespace-class IFS quirk). Hosts/models/tiers cannot
  # contain '|'.
  printf '%s|%s|%s|%s\n' "$host" "$model" "$emit_effort" "$tier"
  return 0
}

COLLISION=false
ESCALATED=false
PICK=""

if [ "${#DIFFERENT_FAMILY[@]}" -gt 0 ]; then
  PICK=$(resolve_against_pool different "$ROLE_TIER" "$ROLE" "$ROLE_EFFORT" "${DIFFERENT_FAMILY[@]}") || PICK=""
fi

if [ -z "$PICK" ] && [ "${#SAME_FAMILY[@]}" -gt 0 ]; then
  COLLISION=true
  ESCALATED_TIER=$(mp_escalate_tier "$ROLE_TIER")
  [ -n "$ESCALATED_TIER" ] || emit_blocked unknown_tier
  [ "$ESCALATED_TIER" != "$ROLE_TIER" ] && ESCALATED=true
  COLL_FLOOR=$(mp_collision_effort_floor)
  COLL_EFFORT="${COLL_FLOOR:-$ROLE_EFFORT}"
  PICK=$(resolve_against_pool same "$ESCALATED_TIER" "$ROLE" "$COLL_EFFORT" "${SAME_FAMILY[@]}") || PICK=""
fi

[ -n "$PICK" ] || emit_blocked no_catalog_match

IFS='|' read -r OUT_HOST OUT_MODEL OUT_EFFORT OUT_TIER <<<"$PICK"

printf 'STUDIO_REVIEWER_HOST=%s\n' "$OUT_HOST"
printf 'STUDIO_REVIEWER_MODEL=%s\n' "$OUT_MODEL"
printf 'STUDIO_REVIEWER_REASONING_EFFORT=%s\n' "$OUT_EFFORT"
printf 'STUDIO_REVIEWER_TIER=%s\n' "$OUT_TIER"
printf 'STUDIO_REVIEWER_FAMILY_COLLISION=%s\n' "$COLLISION"
printf 'STUDIO_REVIEWER_ESCALATED=%s\n' "$ESCALATED"
printf 'STUDIO_REVIEWER_IMPL_HOST=%s\n' "${IMPL_HOST:-unknown}"
printf 'STUDIO_REVIEWER_IMPL_FAMILY=%s\n' "${IMPL_FAMILY:-}"
