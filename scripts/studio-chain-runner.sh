#!/usr/bin/env bash
# studio-chain-runner.sh - execute issue chains with fresh host sessions.
#
# Usage:
#   scripts/studio-chain-runner.sh chains.yaml [--only <chain>] [--host <host>] [--dry-run]
#
# Manifest shape:
#   schema_version: 1
#   chains:
#     - name: field-telemetry-mvp
#       base: main
#       branch: feature/field-telemetry-mvp
#       host: auto
#       issues: [384, 313, 223]

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage

MANIFEST=""
ONLY_CHAIN=""
HOST_OVERRIDE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY_CHAIN="${2:?--only requires a chain name}"; shift 2 ;;
    --only=*) ONLY_CHAIN="${1#--only=}"; shift ;;
    --host) HOST_OVERRIDE="${2:?--host requires a host name}"; shift 2 ;;
    --host=*) HOST_OVERRIDE="${1#--host=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'studio-chain-runner: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      if [ -n "$MANIFEST" ]; then
        printf 'studio-chain-runner: manifest already set: %s\n' "$MANIFEST" >&2
        usage
      fi
      MANIFEST="$1"
      shift
      ;;
  esac
done

[ -n "$MANIFEST" ] || usage
[ -f "$MANIFEST" ] || { printf 'studio-chain-runner: manifest not found: %s\n' "$MANIFEST" >&2; exit 2; }

command -v yq >/dev/null 2>&1 || { printf 'studio-chain-runner: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { printf 'studio-chain-runner: gh required\n' >&2; exit 2; }

REPO_SLUG="v-i-s-h-a-l/generic-dev-studio"
RUN_ROOT="${TMPDIR:-/tmp}/studio-chain-runner"
mkdir -p "$RUN_ROOT"
FINAL_PR_URL=""

log() {
  printf 'studio-chain-runner: %s\n' "$*" >&2
}

slugify() {
  printf '%s' "$1" | tr '/[:space:]' '--' | tr -cd '[:alnum:]_.-'
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

validate_branch_ref() {
  local ref="$1" label="$2"
  if ! git check-ref-format --branch "$ref" >/dev/null 2>&1; then
    printf 'studio-chain-runner: invalid %s branch name: %s\n' "$label" "$ref" >&2
    exit 2
  fi
}

validate_chain_branch() {
  local branch="$1" base="$2"
  validate_branch_ref "$base" "base"
  validate_branch_ref "$branch" "chain"

  if [ "$branch" = "$base" ]; then
    printf 'studio-chain-runner: chain branch must not equal base branch: %s\n' "$branch" >&2
    exit 2
  fi

  case "$branch" in
    main|master|trunk|develop|production)
      printf 'studio-chain-runner: refusing protected chain branch: %s\n' "$branch" >&2
      exit 2
      ;;
  esac
}

host_spawn_command() {
  local host="$1" manifest spawn
  manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT") || {
    printf 'studio-chain-runner: host "%s" has no capabilities manifest\n' "$host" >&2
    return 1
  }
  [ -f "$manifest" ] || {
    printf 'studio-chain-runner: missing host manifest: %s\n' "$manifest" >&2
    return 1
  }
  spawn=$(grep -E '^spawn_command:[[:space:]]' "$manifest" | head -1 | sed 's/^spawn_command:[[:space:]]*//' | tr -d '"'"'")
  [ -n "$spawn" ] || {
    printf 'studio-chain-runner: %s missing spawn_command\n' "$manifest" >&2
    return 1
  }
  printf '%s\n' "$spawn"
}

chain_count=$(yq -r '.chains | length' "$MANIFEST")
case "$chain_count" in
  ''|null|*[!0-9]*)
    printf 'studio-chain-runner: manifest must contain chains[]\n' >&2
    exit 2
    ;;
esac

if [ "$chain_count" -eq 0 ]; then
  printf 'studio-chain-runner: manifest has no chains\n' >&2
  exit 2
fi

execute_issue_session() {
  local chain_name="$1" chain_branch="$2" issue="$3" host="$4" worktree="$5"
  local issue_json issue_title issue_body spawn prompt
  local -a spawn_argv

  issue_json=$(gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,body,url,state)
  issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
  issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')

  spawn=$(host_spawn_command "$host")
  # shellcheck disable=SC2206
  spawn_argv=( $spawn )

  prompt=$(cat <<EOF
Implement this studio issue in a fresh chain-runner session.

You are executing one issue inside an automated chain runner.

Repo: $REPO_SLUG
Chain: $chain_name
Chain branch: $chain_branch
Issue: #$issue - $issue_title
Working directory: $worktree

Rules:
- Work only in this working directory.
- Implement only issue #$issue.
- Keep changes scoped to this issue.
- Commit the result on the current branch.
- Include "Closes #$issue" in the commit message.
- Do not open a PR.
- Do not merge to main.
- Do not close the issue; the chain runner owns issue closure after integration.
- If blocked, exit non-zero after writing a concise reason.

Issue body:
$issue_body
EOF
)

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN cd %q && ' "$worktree"
    printf '%q ' "${spawn_argv[@]}"
    printf '%q\n' "$prompt"
    return 0
  fi

  (cd "$worktree" && "${spawn_argv[@]}" "$prompt")
}

finalize_chain_pr() {
  local chain_name="$1" chain_branch="$2" chain_worktree="$3" base="$4"
  local pr_url pr_number

  log "rebasing $chain_branch on origin/$base"
  run git -C "$chain_worktree" fetch origin --prune
  run git -C "$chain_worktree" rebase "origin/$base"
  run git -C "$chain_worktree" push -u origin "$chain_branch"

  if [ "$DRY_RUN" -eq 1 ]; then
    FINAL_PR_URL="<dry-run-pr-url>"
    printf 'DRY-RUN gh pr create --base %q --head %q --title %q --body ...\n' "$base" "$chain_branch" "$chain_name"
    printf 'DRY-RUN scripts/pr-headless-review.sh <pr> --method auto\n'
    return 0
  fi

  pr_url=$(gh pr create \
    --repo "$REPO_SLUG" \
    --base "$base" \
    --head "$chain_branch" \
    --title "studio chain: $chain_name" \
    --body "Automated chain PR for \`$chain_name\`.

Run by \`scripts/studio-chain-runner.sh\`.

Review gate: \`scripts/pr-headless-review.sh <pr> --method auto\`.")
  pr_number=$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  FINAL_PR_URL="$pr_url"
  log "opened PR $pr_url"
  "$SCRIPT_DIR/pr-headless-review.sh" "$pr_number" --method auto
}

for ((idx = 0; idx < chain_count; idx++)); do
  name=$(yq -r ".chains[$idx].name" "$MANIFEST")
  base=$(yq -r ".chains[$idx].base // \"main\"" "$MANIFEST")
  branch=$(yq -r ".chains[$idx].branch // (\"feature/\" + .chains[$idx].name)" "$MANIFEST")
  host=$(yq -r ".chains[$idx].host // \"auto\"" "$MANIFEST")
  issue_count=$(yq -r ".chains[$idx].issues | length" "$MANIFEST")

  [ -n "$ONLY_CHAIN" ] && [ "$name" != "$ONLY_CHAIN" ] && { log "skip chain $name (--only $ONLY_CHAIN)"; continue; }
  validate_chain_branch "$branch" "$base"
  [ "$host" = "auto" ] && host="${HOST_OVERRIDE:-codex}"
  [ -n "$HOST_OVERRIDE" ] && host="$HOST_OVERRIDE"

  case "$issue_count" in
    ''|null|*[!0-9]*|0)
      printf 'studio-chain-runner: chain %s has no issues\n' "$name" >&2
      exit 2
      ;;
  esac

  chain_slug=$(slugify "$name")
  chain_worktree="$RUN_ROOT/$chain_slug-feature"

  log "starting chain $name on $branch from latest $base using host=$host"
  run git -C "$REPO_ROOT" fetch origin --prune
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -d "$chain_worktree/.git" ]; then
      git -C "$REPO_ROOT" worktree add -B "$branch" "$chain_worktree" "origin/$base"
    fi
    git -C "$chain_worktree" checkout "$branch"
    git -C "$chain_worktree" reset --hard "origin/$base"
  else
    printf 'DRY-RUN git worktree add -B %q %q origin/%q\n' "$branch" "$chain_worktree" "$base"
  fi

  for ((i = 0; i < issue_count; i++)); do
    issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
    issue_slug=$(slugify "$issue")
    issue_branch="$branch-issue-$issue_slug"
    issue_worktree="$RUN_ROOT/$chain_slug-issue-$issue_slug"

    log "issue #$issue -> $issue_branch"
    if [ "$DRY_RUN" -eq 0 ]; then
      git -C "$REPO_ROOT" worktree remove --force "$issue_worktree" 2>/dev/null || rm -rf "$issue_worktree"
      git -C "$REPO_ROOT" worktree add -B "$issue_branch" "$issue_worktree" "$branch"
      before=$(git -C "$issue_worktree" rev-parse HEAD)
    else
      printf 'DRY-RUN git worktree add -B %q %q %q\n' "$issue_branch" "$issue_worktree" "$branch"
      before="dry-run-before"
    fi

    execute_issue_session "$name" "$branch" "$issue" "$host" "$issue_worktree"

    if [ "$DRY_RUN" -eq 0 ]; then
      after=$(git -C "$issue_worktree" rev-parse HEAD)
      if [ "$after" = "$before" ]; then
        printf 'studio-chain-runner: issue #%s produced no commit; leaving worktree at %s\n' "$issue" "$issue_worktree" >&2
        exit 1
      fi
      git -C "$chain_worktree" checkout "$branch"
      git -C "$chain_worktree" merge --ff-only "$issue_branch"
      git -C "$REPO_ROOT" worktree remove "$issue_worktree"
      git -C "$REPO_ROOT" branch -D "$issue_branch"
    else
      printf 'DRY-RUN git -C %q checkout %q\n' "$chain_worktree" "$branch"
      printf 'DRY-RUN git -C %q merge --ff-only %q\n' "$chain_worktree" "$issue_branch"
      printf 'DRY-RUN git -C %q worktree remove %q\n' "$REPO_ROOT" "$issue_worktree"
      printf 'DRY-RUN git -C %q branch -D %q\n' "$REPO_ROOT" "$issue_branch"
    fi
  done

  finalize_chain_pr "$name" "$branch" "$chain_worktree" "$base"

  for ((i = 0; i < issue_count; i++)); do
    issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
    if [ "$DRY_RUN" -eq 0 ]; then
      gh issue close "$issue" --repo "$REPO_SLUG" --comment "Merged through chain PR: ${FINAL_PR_URL:-$branch}" \
        || gh issue comment "$issue" --repo "$REPO_SLUG" --body "Merged through chain PR: ${FINAL_PR_URL:-$branch}"
    else
      printf 'DRY-RUN gh issue close %q --repo %q --comment %q\n' "$issue" "$REPO_SLUG" "Merged through chain PR: ${FINAL_PR_URL:-<pr-url>}"
    fi
  done

  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO_ROOT" fetch origin --prune
    git -C "$REPO_ROOT" worktree remove "$chain_worktree" || true
    git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
  else
    printf 'DRY-RUN git -C %q fetch origin --prune\n' "$REPO_ROOT"
    printf 'DRY-RUN git -C %q worktree remove %q\n' "$REPO_ROOT" "$chain_worktree"
    printf 'DRY-RUN git -C %q branch -D %q\n' "$REPO_ROOT" "$branch"
  fi
done

log "all requested chains processed"
