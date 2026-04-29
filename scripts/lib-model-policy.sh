#!/usr/bin/env bash
# lib-model-policy.sh — pure shell+yq helpers for reviewer model selection.
#
# Pairs with _shared/schemas/model-catalog.yaml and _shared/rules/model-policy.yaml.
# Sourced by scripts/resolve-reviewer.sh and tests under
# scripts/test-fixtures/322-model-catalog/. Zero LLM tokens are spent on
# selection — every function is a yq read.
#
# Targets mikefarah/yq (Go). The ambient toolchain in this repo is mikefarah/yq
# v4 (see scripts/pr-reviewer-eligibility.sh); kislyuk/yq is not used.
#
# All functions resolve their inputs from the calling shell:
#   STUDIO_MODEL_CATALOG_FILE  — path to model-catalog.yaml
#   STUDIO_MODEL_POLICY_FILE   — path to model-policy.yaml
#   STUDIO_HOSTS_REGISTRY_FILE — path to hosts/registry.yaml
# The resolver script sets these to repo-rooted defaults; tests can override
# via env to point at synthetic fixtures.

# shellcheck shell=bash

mp_require_files() {
  # NOTE: avoid local 'path' — zsh ties $path to the $PATH array; shadowing it
  # inside a function breaks subsequent `command -v` lookups.
  local missing=0 var mp_path_value
  for var in STUDIO_MODEL_CATALOG_FILE STUDIO_MODEL_POLICY_FILE STUDIO_HOSTS_REGISTRY_FILE; do
    eval "mp_path_value=\"\${$var:-}\""
    if [ -z "$mp_path_value" ]; then
      printf 'lib-model-policy: %s is unset\n' "$var" >&2
      missing=1
    elif [ ! -f "$mp_path_value" ]; then
      printf 'lib-model-policy: %s does not exist: %s\n' "$var" "$mp_path_value" >&2
      missing=1
    fi
  done
  command -v yq >/dev/null 2>&1 || {
    printf 'lib-model-policy: yq is required\n' >&2
    missing=1
  }
  return "$missing"
}

# Echo a value or empty string when the result is null. mikefarah/yq prints
# the literal string "null" for missing keys when the expression returns null.
mp__or_empty() {
  local v="$1"
  [ "$v" = "null" ] && printf '\n' || printf '%s\n' "$v"
}

# Resolve a host name to its provider family from hosts/registry.yaml.
# Echoes the family or empty string when the host is unknown / has no family.
mp_provider_family_for_host() {
  local host="$1"
  [ -n "$host" ] || { printf '\n'; return 0; }
  local family
  family=$(STUDIO_MP_KEY="$host" yq -r '.[env(STUDIO_MP_KEY)].provider_family // ""' "$STUDIO_HOSTS_REGISTRY_FILE" 2>/dev/null)
  mp__or_empty "$family"
}

# Echo the index (0-based) of a tier within the catalog's intelligence_tiers
# list, or empty string when the tier is unknown. Used to compare and escalate.
mp_tier_index() {
  local tier="$1"
  [ -n "$tier" ] || { printf '\n'; return 0; }
  local idx
  idx=$(STUDIO_MP_TIER="$tier" yq -r '
    .intelligence_tiers
    | to_entries
    | map(select(.value == env(STUDIO_MP_TIER)))
    | (.[0].key // "")
  ' "$STUDIO_MODEL_CATALOG_FILE" 2>/dev/null)
  mp__or_empty "$idx"
}

# Echo the next tier above the given one, or the same tier when already at the
# top of the ordered list. Empty string if the input tier is unknown.
mp_escalate_tier() {
  local tier="$1"
  local idx
  idx=$(mp_tier_index "$tier")
  [ -n "$idx" ] || { printf '\n'; return 0; }
  local next
  next=$(STUDIO_MP_IDX="$idx" yq -r '
    .intelligence_tiers as $t
    | (env(STUDIO_MP_IDX) | tonumber) as $i
    | ($t | length - 1) as $last
    | ($i + 1) as $next
    | ([$next, $last] | min) as $clamped
    | $t[$clamped]
  ' "$STUDIO_MODEL_CATALOG_FILE" 2>/dev/null)
  mp__or_empty "$next"
}

# Echo the policy tier for a given role tag, or empty string when the role is
# not declared in model-policy.yaml.
mp_role_tier() {
  local role="$1"
  [ -n "$role" ] || { printf '\n'; return 0; }
  local v
  v=$(STUDIO_MP_KEY="$role" yq -r '.roles[env(STUDIO_MP_KEY)].tier // ""' "$STUDIO_MODEL_POLICY_FILE" 2>/dev/null)
  mp__or_empty "$v"
}

# Echo the policy reasoning_effort for a given role tag.
mp_role_effort() {
  local role="$1"
  [ -n "$role" ] || { printf '\n'; return 0; }
  local v
  v=$(STUDIO_MP_KEY="$role" yq -r '.reasoning_effort[env(STUDIO_MP_KEY)] // ""' "$STUDIO_MODEL_POLICY_FILE" 2>/dev/null)
  mp__or_empty "$v"
}

# Echo the same-family-collision reasoning_effort floor.
mp_collision_effort_floor() {
  local v
  v=$(yq -r '.reasoning_effort.same_family_collision_floor // ""' "$STUDIO_MODEL_POLICY_FILE" 2>/dev/null)
  mp__or_empty "$v"
}

# Echo the first model id in the catalog whose provider_family, intelligence_tier,
# and roles all match. Empty string when no model matches.
mp_pick_model() {
  local family="$1" tier="$2" role="$3"
  local v
  v=$(STUDIO_MP_FAM="$family" STUDIO_MP_TIER="$tier" STUDIO_MP_ROLE="$role" yq -r '
    .models
    | map(select(
        .provider_family == env(STUDIO_MP_FAM)
        and .intelligence_tier == env(STUDIO_MP_TIER)
        and (.roles | contains([env(STUDIO_MP_ROLE)]))
      ))
    | (.[0].id // "")
  ' "$STUDIO_MODEL_CATALOG_FILE" 2>/dev/null)
  mp__or_empty "$v"
}

# Echo "true" when any catalog entry for this family supports reasoning_effort.
mp_family_supports_effort() {
  local family="$1"
  [ -n "$family" ] || { printf 'false\n'; return 0; }
  local val
  val=$(STUDIO_MP_FAM="$family" yq -r '
    [.models[] | select(.provider_family == env(STUDIO_MP_FAM)) | .reasoning_effort_supported]
    | any
  ' "$STUDIO_MODEL_CATALOG_FILE" 2>/dev/null)
  [ "$val" = "true" ] && printf 'true\n' || printf 'false\n'
}

# Echo every adapted host name in the registry that has a capabilities_path.
# The caller still gates each through the eligibility script for runtime checks.
mp_reviewer_hosts_in_registry() {
  yq -r '
    to_entries
    | map(select(
        (.value | type == "!!map")
        and (.value.capabilities_path != null)
        and (.value.status == "adapted")
      ))
    | .[].key
  ' "$STUDIO_HOSTS_REGISTRY_FILE" 2>/dev/null
}
