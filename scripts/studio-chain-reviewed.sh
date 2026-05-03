#!/usr/bin/env bash
# studio-chain-reviewed.sh — plan-review a chain, then run it with reviewed PR merges.
#
# Usage:
#   scripts/studio-chain-reviewed.sh <manifest-or-name> [--host codex|claude-code] [--review-host claude-reviewer|codex-reviewer] [--dry-run]
#
# The wrapper is intentionally thin:
#   1. Write a private phase-plan artifact for the chain run.
#   2. Review that plan through scripts/phase-review.sh.
#   3. Run scripts/studio-chain-runner.sh with STUDIO_REVIEW_HOST pinned, so
#      every chain PR merge goes through scripts/pr-headless-review.sh with the
#      selected reviewer host.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

MANIFEST_ARG=""
HOST="codex"
REVIEW_HOST="claude-reviewer"
DRY_RUN=0
USE_CAFFEINATE=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host requires a value}"; shift 2 ;;
    --host=*) HOST="${1#--host=}"; shift ;;
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --review-host=*) REVIEW_HOST="${1#--review-host=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-caffeinate) USE_CAFFEINATE=0; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'studio-chain-reviewed: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      if [ -n "$MANIFEST_ARG" ]; then
        printf 'studio-chain-reviewed: manifest already set: %s\n' "$MANIFEST_ARG" >&2
        usage
      fi
      MANIFEST_ARG="$1"
      shift
      ;;
  esac
done

[ -n "$MANIFEST_ARG" ] || usage

command -v yq >/dev/null 2>&1 || { printf 'studio-chain-reviewed: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-reviewed: jq required\n' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { printf 'studio-chain-reviewed: gh required\n' >&2; exit 2; }

case "$HOST" in
  codex|claude-code|auto) ;;
  *) printf 'studio-chain-reviewed: --host must be codex, claude-code, or auto\n' >&2; exit 2 ;;
esac

case "$REVIEW_HOST" in
  claude-reviewer|codex-reviewer) ;;
  *) printf 'studio-chain-reviewed: --review-host must be claude-reviewer or codex-reviewer\n' >&2; exit 2 ;;
esac

resolve_manifest() {
  local arg="$1"
  if [ -f "$arg" ]; then
    printf '%s\n' "$arg"
    return 0
  fi
  if [ -f "$REPO_ROOT/chains/$arg.yaml" ]; then
    printf '%s\n' "$REPO_ROOT/chains/$arg.yaml"
    return 0
  fi
  if [ -f "$REPO_ROOT/chains/$arg.yml" ]; then
    printf '%s\n' "$REPO_ROOT/chains/$arg.yml"
    return 0
  fi
  return 1
}

slugify() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

review_allows_execution() {
  local verdict="$1"
  [ "$verdict" = "clean" ]
}

PARENT_HOME_FOR_GITHUB=$(resolve_parent_home_for_github)

MANIFEST_PATH=$(resolve_manifest "$MANIFEST_ARG") || {
  printf 'studio-chain-reviewed: manifest not found: %s\n' "$MANIFEST_ARG" >&2
  exit 2
}

MANIFEST_DISPLAY="$MANIFEST_ARG"
case "$MANIFEST_PATH" in
  "$REPO_ROOT"/*) MANIFEST_DISPLAY="${MANIFEST_PATH#$REPO_ROOT/}" ;;
esac

schema_version=$(yq -r '.schema_version // ""' "$MANIFEST_PATH")
[ "$schema_version" = "1" ] || {
  printf 'studio-chain-reviewed: unsupported schema_version in %s: %s\n' "$MANIFEST_DISPLAY" "$schema_version" >&2
  exit 2
}

chain_count=$(yq -r '.chains | length' "$MANIFEST_PATH")
case "$chain_count" in
  ''|null|*[!0-9]*|0)
    printf 'studio-chain-reviewed: manifest has no chains: %s\n' "$MANIFEST_DISPLAY" >&2
    exit 2
    ;;
esac

run_stamp=$(date -u +%Y%m%dT%H%M%SZ)
manifest_slug=$(slugify "$(basename "$MANIFEST_PATH" | sed -E 's/[.][^.]+$//')")
analysis_root=$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_analysis_root)
mkdir -p "$analysis_root"
plan_file="$analysis_root/${run_stamp}-${manifest_slug}-chain-plan.md"
review_file="$analysis_root/${run_stamp}-${manifest_slug}-chain-plan-review.md"

chain_table=$(CHAIN_MANIFEST="$MANIFEST_PATH" yq -r '
  .chains[]
  | "- `" + .name + "` -> branch `" + (.branch // ("feature/" + .name)) + "`, base `" + (.base // "main") + "`, host `" + (.host // "auto") + "`, issues [" + ((.issues // []) | map(tostring) | join(", ")) + "]"
' "$MANIFEST_PATH")

issue_set=$(yq -r '.chains[].issues[] | tostring' "$MANIFEST_PATH" | sort -n | paste -sd ' ' -)
if [ "$DRY_RUN" -eq 1 ]; then
  execution_mode_text="Dry-run mode: validate the plan-review gate and chain-runner orchestration without creating branches, PRs, reviews, merges, issue closures, or cleanup mutations."
  pr_review_acceptance="- Dry-run mode does not exercise real PR merge reviews; it must print the chain-runner PR-review command shape for each chain."
  side_effect_scope="- No GitHub or git mutations are expected because this is a dry run."
else
  execution_mode_text="Wet-run mode: execute the chain manifest, create issue worktrees and chain PRs, run reviewed merges, close issues after successful merges, and clean up."
  pr_review_acceptance="- Every chain PR merge uses \`scripts/pr-headless-review.sh\` through the chain runner, with \`STUDIO_REVIEW_HOST=$REVIEW_HOST\`."
  side_effect_scope="- GitHub branches, PRs, reviews, merges, issue closures, and cleanup are expected if review gates pass."
fi

cat > "$plan_file" <<EOF
# Reviewed Studio Chain Run Plan

## Goal

Run the studio chain manifest \`$MANIFEST_DISPLAY\` with a sibling-host plan review before execution and reviewer-gated PR merges during wet-run execution.

## Scope

In:
- Execute \`scripts/phase-review.sh --review-host $REVIEW_HOST\` against this plan before starting any chain work.
- Execute \`scripts/studio-chain-runner.sh $MANIFEST_ARG --host $HOST\` only if the plan review reports nothing fatal.
- Pin chain PR merge review to \`$REVIEW_HOST\` via \`STUDIO_REVIEW_HOST=$REVIEW_HOST\`.
- Mark the implementation parent host as \`$HOST\` via \`STUDIO_PARENT_HOST=$HOST\` so PR review remains cross-host when using \`claude-reviewer\` for Codex workers.
- Let the chain runner create issue worktrees, issue branches, chain PRs, PR reviews, merges, issue closures, cleanup, and private chain reports.
- $execution_mode_text
- $side_effect_scope

Out:
- Do not bypass review gates.
- Do not skip blocked PR reviews; if a review blocks, the chain runner must stop before downstream chains.
- Do not mutate the chain manifest during execution.

## Chain Manifest

- Manifest: \`$MANIFEST_DISPLAY\`
- Schema: \`$schema_version\`
- Chain count: \`$chain_count\`
- Issue set: \`$issue_set\`
- Dry run: \`$DRY_RUN\`

## Ordered Chains

$chain_table

## Execution Command

\`\`\`sh
STUDIO_PARENT_HOST=$HOST STUDIO_REVIEW_HOST=$REVIEW_HOST scripts/studio-chain-runner.sh $MANIFEST_ARG --host $HOST$( [ "$DRY_RUN" -eq 1 ] && printf ' --dry-run' || printf ' --yes' )
\`\`\`

## Acceptance Criteria

- The plan review is archived at \`$review_file\`.
- The chain runner starts only after the review says "nothing fatal", "no fatal blockers", or an equivalent clean/proceed verdict.
$pr_review_acceptance
- If any PR review blocks, downstream chains are not executed.
- No hard wall-clock timeout is applied by this wrapper; unattended wet runs rely on the chain runner's per-step failures and the operator log for diagnosis.

## Explicit Ask

Review whether this chain execution plan is safe to start unattended. What is still wrong or missing?
EOF

printf 'studio-chain-reviewed: reviewing plan with %s\n' "$REVIEW_HOST" >&2
review_meta=$(HOME="$PARENT_HOME_FOR_GITHUB" "$SCRIPT_DIR/phase-review.sh" \
  --review-host "$REVIEW_HOST" \
  --kind plan \
  --input "$plan_file" \
  --output "$review_file")
printf '%s\n' "$review_meta"
review_verdict=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_VERDICT=//p' | tail -1)
[ -n "$review_verdict" ] || review_verdict="ambiguous"

if ! review_allows_execution "$review_verdict"; then
  printf 'studio-chain-reviewed: plan review verdict is %s; not starting chain\n' "$review_verdict" >&2
  printf 'studio-chain-reviewed: review file: %s\n' "$review_file" >&2
  exit 1
fi

runner_cmd=("$SCRIPT_DIR/studio-chain-runner.sh" "$MANIFEST_ARG" --host "$HOST")
if [ "$DRY_RUN" -eq 0 ]; then
  runner_cmd+=(--yes)
else
  runner_cmd+=(--dry-run)
fi

printf 'studio-chain-reviewed: plan review accepted: %s\n' "$review_file" >&2
printf 'studio-chain-reviewed: starting chain with STUDIO_REVIEW_HOST=%s STUDIO_PARENT_HOST=%s\n' "$REVIEW_HOST" "$HOST" >&2

export STUDIO_REVIEW_HOST="$REVIEW_HOST"
export STUDIO_PARENT_HOST="$HOST"

if [ "$USE_CAFFEINATE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && command -v caffeinate >/dev/null 2>&1; then
  exec caffeinate -dimsu "${runner_cmd[@]}"
fi

exec "${runner_cmd[@]}"
