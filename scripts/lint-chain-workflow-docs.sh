#!/usr/bin/env bash
# lint-chain-workflow-docs.sh - keep chain-runner docs aligned with the command contract.
#
# Usage:
#   scripts/lint-chain-workflow-docs.sh [--staged|--full]
#
# Override:
#   STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS=1 scripts/lint-chain-workflow-docs.sh --staged

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

MODE="full"
case "${1:-}" in
  --staged) MODE="staged" ;;
  --full|"") MODE="full" ;;
  *) printf 'usage: lint-chain-workflow-docs.sh [--staged|--full]\n' >&2; exit 2 ;;
esac

if [ "${STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS:-0}" = "1" ]; then
  printf 'lint-chain-workflow-docs: skipped by STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS=1 (%s)\n' "$MODE" >&2
  exit 0
fi

ERRORS=0

emit_error() {
  printf '%s\n' "$1" >&2
  ERRORS=$((ERRORS + 1))
}

staged_paths() {
  git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
}

should_check_staged() {
  [ "$MODE" = "staged" ] || return 0
  staged_paths | grep -Eq '^(\.githooks/pre-commit|README\.md|scripts/README\.md|core/v2/skills/dev-studio/SKILL\.md|scripts/(studio-chain-runner|manager-work-chain|lint-chain-workflow-docs)\.sh|scripts/test-fixtures/(446-chain-mode-enhancements|655-manager-work-chain)/)' 2>/dev/null
}

require_file_contains() {
  local rel="$1" needle="$2" code="$3" reason="$4"
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    emit_error "$code:$rel | missing file"
    return 0
  fi
  if ! grep -Fq -- "$needle" "$REPO_ROOT/$rel"; then
    emit_error "$code:$rel:missing=$needle | $reason"
  fi
}

check_public_docs() {
  local doc
  for doc in README.md scripts/README.md; do
    require_file_contains "$doc" 'scripts/studio-chain-runner.sh --discover' \
      E_CHAIN_DOC_DISCOVER 'document bare discovery before chain work starts'
    require_file_contains "$doc" 'scripts/studio-chain-runner.sh --discover prd-to-chain-automation' \
      E_CHAIN_DOC_FILTERED_DISCOVER 'document filtered discovery for a manifest or chain name'
    require_file_contains "$doc" 'scripts/manager-work-chain.sh prd-to-chain-automation --dry-run' \
      E_CHAIN_DOC_MANAGER_PREVIEW 'document manager front-door preview'
    require_file_contains "$doc" 'scripts/studio-chain-runner.sh --auto workflow-measurement-improvements' \
      E_CHAIN_DOC_AUTO 'document unattended supervisor auto mode'
    require_file_contains "$doc" 'scripts/studio-chain-runner.sh workflow-measurement-improvements --attended --yes' \
      E_CHAIN_DOC_ATTENDED 'document attended execution mode'
    require_file_contains "$doc" 'scripts/studio-chain-runner.sh workflow-measurement-improvements --unattended --yes' \
      E_CHAIN_DOC_UNATTENDED 'document unattended execution mode'
  done
}

check_router_docs() {
  require_file_contains core/v2/skills/dev-studio/SKILL.md 'manager work-chain' \
    E_CHAIN_ROUTER_WORK_CHAIN 'dev-studio skill must route the manager work-chain front door'
  require_file_contains core/v2/skills/dev-studio/SKILL.md '`--discover <manifest|chain-name>`' \
    E_CHAIN_ROUTER_FILTERED_DISCOVER 'dev-studio skill must name the filtered discovery contract'
  require_file_contains core/v2/skills/dev-studio/SKILL.md '`--attended` and `--unattended`' \
    E_CHAIN_ROUTER_EXECUTION_MODE 'dev-studio skill must name execution modes'
}

check_runner_contract() {
  require_file_contains scripts/studio-chain-runner.sh 'scripts/studio-chain-runner.sh [--discover [<manifest|chain-name>] [--only <chain>]]' \
    E_CHAIN_RUNNER_USAGE_DISCOVER 'runner usage must expose filtered discovery and --only'
  require_file_contains scripts/studio-chain-runner.sh 'Bare invocation is discovery-only; it never starts or resumes work.' \
    E_CHAIN_RUNNER_DISCOVERY_ONLY 'bare runner invocation must remain non-mutating discovery'
  require_file_contains scripts/studio-chain-runner.sh 'Add a manifest or chain name to filter suggestions' \
    E_CHAIN_RUNNER_FILTER_COPY 'discovery output must explain filtered suggestions'
  require_file_contains scripts/studio-chain-runner.sh '--auto is unattended' \
    E_CHAIN_RUNNER_AUTO_MODE 'auto mode must stay unattended unless the contract changes deliberately'
}

check_manager_wrapper_contract() {
  require_file_contains scripts/manager-work-chain.sh 'exec "$RUNNER" --discover' \
    E_CHAIN_MANAGER_BARE_DISCOVER 'bare manager work-chain must land in discovery'
  require_file_contains scripts/manager-work-chain.sh 'exec "$RUNNER" --auto "$@"' \
    E_CHAIN_MANAGER_NAMED_AUTO 'named manager work-chain must default to supervisor auto mode'
  require_file_contains scripts/manager-work-chain.sh 'Use --discover [<manifest|chain-name>] for filtered, non-mutating discovery.' \
    E_CHAIN_MANAGER_FILTERED_USAGE 'manager wrapper help must document filtered non-mutating discovery'
}

check_fixtures() {
  require_file_contains scripts/test-fixtures/446-chain-mode-enhancements/test-chain-runner-discover.sh 'scripts/studio-chain-runner.sh" --discover prd-to-chain-automation' \
    E_CHAIN_FIXTURE_FILTERED_DISCOVER 'runner discovery fixture must cover filtered discovery'
  require_file_contains scripts/test-fixtures/446-chain-mode-enhancements/test-chain-runner-discover.sh 'filtered discovery included unrelated runnable chain' \
    E_CHAIN_FIXTURE_FILTER_NEGATIVE 'runner fixture must assert filtered discovery omits unrelated chains'
  require_file_contains scripts/test-fixtures/655-manager-work-chain/test-manager-work-chain.sh '"$RUN" --discover prd-to-chain-automation' \
    E_CHAIN_FIXTURE_MANAGER_FILTERED_DISCOVER 'manager wrapper fixture must cover filtered discovery'
  require_file_contains scripts/test-fixtures/655-manager-work-chain/test-manager-work-chain.sh '"$RUN" prd-to-chain-automation --dry-run' \
    E_CHAIN_FIXTURE_MANAGER_AUTO 'manager wrapper fixture must cover named auto delegation'
}

check_hook_wiring() {
  require_file_contains .githooks/pre-commit '"$SCRIPTS/lint-chain-workflow-docs.sh" --staged' \
    E_CHAIN_HOOK_WIRING 'pre-commit must run the chain workflow docs guard'
  require_file_contains .githooks/pre-commit 'STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS=1' \
    E_CHAIN_HOOK_BYPASS 'pre-commit must document the user-controlled guard override'
}

should_check_staged || {
  printf 'lint-chain-workflow-docs: ok (%s, no chain workflow docs surface)\n' "$MODE" >&2
  exit 0
}

check_public_docs
check_router_docs
check_runner_contract
check_manager_wrapper_contract
check_fixtures
check_hook_wiring

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-chain-workflow-docs: %d errors (%s)\n' "$ERRORS" "$MODE" >&2
  exit 1
fi

printf 'lint-chain-workflow-docs: ok (%s)\n' "$MODE" >&2
exit 0
