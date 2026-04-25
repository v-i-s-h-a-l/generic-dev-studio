#!/usr/bin/env bash
# update-recipes.sh — refresh every auto-pr recipe by checking upstream HEAD.
#
# For each recipe with `update_policy: auto-pr`, fetches the latest commit SHA
# on the source's branch, compares to pinned_sha, and on drift opens a PR
# (never auto-merged) bumping the recipe + re-vendoring the content. Each PR
# carries the lint result, a diff-scan flagging suspicious additions, and an
# event-log entry (`pr_review_ready`) that the SessionStart hook surfaces on
# the next session.
#
# Usage:
#   scripts/update-recipes.sh                    # check + open PRs for all
#                                                  auto-pr recipes
#   scripts/update-recipes.sh <recipe-name>      # single recipe
#   scripts/update-recipes.sh --dry-run          # report drift without PRs
#   scripts/update-recipes.sh --no-pr            # bump + vendor + commit on
#                                                  current branch; skip PR
#                                                  creation (useful for
#                                                  scripted batch updates
#                                                  off-CI)
#
# Exit codes:
#   0  no drift OR drift handled (PRs opened or commits made)
#   1  validation, fetch, or PR-creation failure
#   2  bad invocation
#
# Designed to run from a cron job or LaunchAgent (no interactive prompts).
# Trust-mode auto-merge is deferred to #170; this MVP always opens PRs.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RECIPES_DIR="$REPO_ROOT/recipes"

if ! command -v yq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  printf 'update-recipes: yq + git required\n' >&2; exit 2
fi

TARGET_NAME=""
DRY_RUN=0
NO_PR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-pr)   NO_PR=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) printf 'update-recipes: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$TARGET_NAME" ]; then TARGET_NAME="$1"
      else printf 'update-recipes: extra argument "%s"\n' "$1" >&2; exit 2
      fi ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fetch_upstream_head() {
  # $1 = author, $2 = repo. Prints the SHA of the upstream's default-branch
  # HEAD via `git ls-remote`. Empty on failure.
  local author="$1" repo="$2" head
  head=$(git ls-remote "https://github.com/$author/$repo.git" HEAD 2>/dev/null \
    | awk '{print $1}' | head -1)
  printf '%s' "$head"
}

diff_scan() {
  # $1 = vendor dir. Greps for tokens that warrant PR-body callouts.
  local dir="$1"
  local hits=""
  if [ ! -d "$dir" ]; then printf ''; return; fi
  # Network / URL surface.
  local urls
  urls=$(grep -rIE 'https?://[a-zA-Z0-9./_-]+' "$dir" 2>/dev/null | wc -l | tr -d '[:space:]')
  # External writes (paths above the skill dir).
  local writes
  writes=$(grep -rIE '(/etc/|/usr/|/var/|/private/|\$HOME/|~/)' "$dir" 2>/dev/null | wc -l | tr -d '[:space:]')
  # Network-call shell tokens.
  local netcalls
  netcalls=$(grep -rIE '\b(curl|wget|nc|fetch|http\.get)\b' "$dir" 2>/dev/null | wc -l | tr -d '[:space:]')
  printf 'urls=%s writes=%s netcalls=%s' "$urls" "$writes" "$netcalls"
}

emit_pr_review_ready() {
  # Best-effort: emit a `pr_review_ready` event into the studio event log.
  local recipe="$1" pr_url="$2" sha="$3" lint_status="$4"
  local emit="$SCRIPT_DIR/emit-event.sh"
  [ -x "$emit" ] || return 0
  "$emit" pr_review_ready \
    recipe="$recipe" pr_url="$pr_url" sha_short="${sha:0:8}" lint="$lint_status" \
    >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Per-recipe update
# ---------------------------------------------------------------------------
update_one_recipe() {
  local recipe_file="$1"
  local recipe_rel="${recipe_file#"$REPO_ROOT/"}"
  local name strategy update_policy
  name=$(yq -r '.name' "$recipe_file")
  strategy=$(yq -r '.strategy' "$recipe_file")
  update_policy=$(yq -r '.update_policy' "$recipe_file")

  if [ "$update_policy" != "auto-pr" ]; then
    return 0
  fi
  if [ "$strategy" = "owned" ]; then
    # Owned recipes have no upstream to track.
    return 0
  fi

  # Single-source recipes only in MVP; multi-source recipes (composite-
  # synthesis) wait on Tier 2 (#171).
  local src_count
  src_count=$(yq -r '.sources | length' "$recipe_file")
  if [ "$src_count" -gt 1 ]; then
    printf 'update-recipes: %s has multi-source recipe (n=%d); MVP only handles single-source\n' "$name" "$src_count" >&2
    return 0
  fi

  local upstream upath pinned_sha
  upstream=$(yq -r '.sources[0].upstream' "$recipe_file")
  upath=$(yq -r '.sources[0].path' "$recipe_file")
  pinned_sha=$(yq -r '.sources[0].pinned_sha' "$recipe_file")
  local author repo
  author=$(printf '%s' "$upstream" | awk -F/ '{print $2}')
  repo=$(printf '%s' "$upstream" | awk -F/ '{print $3}')

  local head_sha
  head_sha=$(fetch_upstream_head "$author" "$repo")
  if [ -z "$head_sha" ]; then
    printf 'update-recipes: %s — could not fetch upstream HEAD for %s/%s\n' "$name" "$author" "$repo" >&2
    return 1
  fi

  if [ "${head_sha:0:7}" = "${pinned_sha:0:7}" ]; then
    return 0
  fi

  printf 'update-recipes: %s drift detected — pinned=%s upstream=%s\n' "$name" "${pinned_sha:0:8}" "${head_sha:0:8}" >&2
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi

  # Branch off main + bump SHA.
  local branch="skills-bump-$name-$(date -u +%Y%m%d)"
  local current_branch
  current_branch=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo HEAD)
  if [ "$NO_PR" -eq 0 ]; then
    git -C "$REPO_ROOT" checkout -B "$branch" >/dev/null 2>&1 || {
      printf 'update-recipes: failed to create branch %s\n' "$branch" >&2; return 1
    }
  fi

  yq -i ".sources[0].pinned_sha = \"$head_sha\"" "$recipe_file"

  # Re-run install-recipe.sh to re-vendor at new SHA.
  if ! "$SCRIPT_DIR/install-recipe.sh" "$name" --auto-approve-author >/dev/null 2>&1; then
    printf 'update-recipes: install-recipe.sh failed for %s @ %s\n' "$name" "$head_sha" >&2
    [ "$NO_PR" -eq 0 ] && git -C "$REPO_ROOT" checkout "$current_branch" >/dev/null 2>&1
    return 1
  fi

  # Linter pass (best-effort signal for the PR body).
  local lint_status="✅"
  if ! "$SCRIPT_DIR/lint-skill-prose.sh" "$REPO_ROOT/skills/vendored/$author/$name" >/dev/null 2>&1; then
    lint_status="❌"
  fi

  # Diff-scan signal.
  local scan
  scan=$(diff_scan "$REPO_ROOT/skills/vendored/$author/$name")

  # Stage + commit.
  git -C "$REPO_ROOT" add "$recipe_rel" "skills/vendored/$author/$name/" 2>/dev/null
  git -C "$REPO_ROOT" commit -m "[skills] bump $name @ ${head_sha:0:8} — lint:$lint_status

$scan

Recipe: $recipe_rel
Upstream: $upstream@$head_sha (was ${pinned_sha:0:8})

Co-Authored-By: scripts/update-recipes.sh <noreply@dev-studio.local>" \
    >/dev/null 2>&1 || {
      printf 'update-recipes: nothing to commit for %s\n' "$name" >&2
      [ "$NO_PR" -eq 0 ] && git -C "$REPO_ROOT" checkout "$current_branch" >/dev/null 2>&1
      return 0
    }

  if [ "$NO_PR" -eq 1 ]; then
    printf 'update-recipes: %s bumped to %s on %s (no PR)\n' "$name" "${head_sha:0:8}" "$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)" >&2
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    printf 'update-recipes: gh not available; commit on %s, no PR opened\n' "$branch" >&2
    return 0
  fi

  git -C "$REPO_ROOT" push -u origin "$branch" >/dev/null 2>&1 || {
    printf 'update-recipes: push of %s failed (no remote, or auth?)\n' "$branch" >&2
    git -C "$REPO_ROOT" checkout "$current_branch" >/dev/null 2>&1
    return 1
  }

  local pr_url
  pr_url=$(gh pr create \
    --base main --head "$branch" \
    --title "[skills] bump $name @ ${head_sha:0:8} — lint:$lint_status" \
    --body "Recipe \`$name\` upstream advanced.

| Field | Before | After |
|---|---|---|
| pinned_sha | \`${pinned_sha:0:8}\` | \`${head_sha:0:8}\` |
| Lint | — | $lint_status |
| Diff-scan | — | $scan |

**Diff-scan signals** (informational; non-blocking):
- \`urls=N\`     — count of \`https?://\` references in vendored content
- \`writes=N\`   — count of paths in protected dirs (\`/etc/\`, \`/usr/\`, \`\$HOME/\`, etc.)
- \`netcalls=N\` — count of network-call shell tokens (\`curl\`, \`wget\`, \`nc\`, \`fetch\`)

If any of these counts changed materially from prior versions, inspect the diff for new exfiltration / network surface before merging.

Recipe file: \`$recipe_rel\`
Vendored at: \`skills/vendored/$author/$name/\`
Upstream: $upstream@$head_sha

Generated by scripts/update-recipes.sh." 2>&1) || {
    printf 'update-recipes: gh pr create failed for %s\n' "$name" >&2
    return 1
  }

  printf 'update-recipes: %s PR opened — %s\n' "$name" "$pr_url" >&2
  emit_pr_review_ready "$name" "$pr_url" "$head_sha" "$lint_status"

  git -C "$REPO_ROOT" checkout "$current_branch" >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
overall_rc=0

if [ -n "$TARGET_NAME" ]; then
  recipe_file=$(find "$RECIPES_DIR" -type f -name "${TARGET_NAME}.yaml" -not -path "*/profiles/*" 2>/dev/null | head -1)
  if [ -z "$recipe_file" ]; then
    printf 'update-recipes: recipe "%s" not found\n' "$TARGET_NAME" >&2; exit 1
  fi
  update_one_recipe "$recipe_file" || overall_rc=1
else
  while IFS= read -r recipe_file; do
    [ -z "$recipe_file" ] && continue
    update_one_recipe "$recipe_file" || overall_rc=1
  done < <(find "$RECIPES_DIR" -type f -name '*.yaml' -not -path "*/profiles/*" 2>/dev/null | sort)
fi

exit "$overall_rc"
