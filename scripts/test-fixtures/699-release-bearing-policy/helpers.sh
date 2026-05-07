#!/usr/bin/env bash
# Shared helpers for the #699 release-bearing policy fixtures.

release_policy_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd
}

release_policy_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

release_policy_require_jq() {
  command -v jq >/dev/null 2>&1 || release_policy_fail "jq required"
}

release_policy_require_yq() {
  command -v yq >/dev/null 2>&1 || release_policy_fail "yq required"
}

release_policy_setup_repo() {
  local repo="${1:?repo required}" chain_worktree="${2:?chain worktree required}" chain_branch="${3:-feature/release-bearing-policy}"

  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Release Policy Fixture"
  mkdir -p "$repo/scripts"
  printf 'base\n' >"$repo/README.md"
  printf '#!/usr/bin/env bash\ntrue\n' >"$repo/scripts/safe.sh"
  git -C "$repo" add README.md scripts/safe.sh
  git -C "$repo" commit -q -m "initial"
  git -C "$repo" branch -M main
  git -C "$repo" worktree add -q -B "$chain_branch" "$chain_worktree" main
  printf 'chain\n' >"$chain_worktree/chain.txt"
  git -C "$chain_worktree" add chain.txt
  git -C "$chain_worktree" commit -q -m "chain anchor"
}

release_policy_load_leaf_gate_functions() {
  local root helper_block
  root=$(release_policy_repo_root)
  # shellcheck source=/dev/null
  . "$root/scripts/lib-chain-git.sh"
  helper_block=$(awk '
    /^chain_policy_audit_log\(\)/ { capture=1 }
    /^live_preflight\(\)/ { capture=0 }
    capture { print }
  ' "$root/scripts/studio-chain-runner.sh")
  eval "$helper_block"
  # shellcheck disable=SC2329 # Called indirectly by eval-loaded runner helpers.
  iso_ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
}

release_policy_prepare_leaf_gate_audit() {
  local tmproot="${1:?tmp root required}" audit_log="${2:?audit log required}"

  # shellcheck disable=SC2034 # Read by eval-loaded runner helpers.
  DRY_RUN=0
  CHAIN_RUN_ROOT="$tmproot/chain-run"
  PLAN_JSON="$tmproot/leaf-gates-plan.json"
  MANIFEST="$tmproot/manifest.yaml"
  mkdir -p "$CHAIN_RUN_ROOT" "$(dirname "$audit_log")"
  printf 'schema_version: 1\n' >"$MANIFEST"
  jq -n --arg audit "$audit_log" '{mechanical_rule_gates:{audit_log:$audit}}' >"$PLAN_JSON"
}
