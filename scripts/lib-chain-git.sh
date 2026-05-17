#!/usr/bin/env bash
# Git workspace helpers for studio-chain-runner issue sessions.

chain_git_prepare_issue_workspace() {
  local repo_root="${1:?usage: chain_git_prepare_issue_workspace <repo-root> <chain-worktree> <chain-branch> <issue-worktree> <issue-branch> <strategy>}"
  local chain_worktree="${2:?chain worktree required}"
  local chain_branch="${3:?chain branch required}"
  local issue_worktree="${4:?issue worktree required}"
  local issue_branch="${5:?issue branch required}"
  local strategy="${6:?git metadata strategy required}"

  case "$strategy" in
    linked-worktree)
      git -C "$repo_root" worktree remove --force "$issue_worktree" 2>/dev/null || rm -rf "$issue_worktree" || return 1
      git -C "$repo_root" worktree add -B "$issue_branch" "$issue_worktree" "$chain_branch" || return 1
      ;;
    local-clone)
      rm -rf "$issue_worktree" || return 1
      git clone --quiet --no-local --branch "$chain_branch" "$chain_worktree" "$issue_worktree" || return 1
      git -C "$issue_worktree" checkout -q -B "$issue_branch" "$chain_branch" || return 1
      ;;
    *)
      printf 'chain-git: unknown git metadata strategy: %s\n' "$strategy" >&2
      return 2
      ;;
  esac
}

# shellcheck disable=SC2034 # CHAIN_GIT_RELEASE_LEAF_DETAIL is consumed by callers.
chain_git_release_leaf_ancestry_ok() {
  local issue_worktree="${1:?usage: chain_git_release_leaf_ancestry_ok <issue-worktree> <commit-before> [context]}"
  local commit_before="${2:?commit before required}"
  local context="${3:-release-bearing leaf}"

  CHAIN_GIT_RELEASE_LEAF_DETAIL=""
  if ! git -C "$issue_worktree" cat-file -e "$commit_before^{commit}" 2>/dev/null; then
    CHAIN_GIT_RELEASE_LEAF_DETAIL="$context cannot resolve launch chain commit $commit_before"
    return 1
  fi
  if git -C "$issue_worktree" merge-base --is-ancestor "$commit_before" HEAD 2>/dev/null; then
    CHAIN_GIT_RELEASE_LEAF_DETAIL="$context descends from launch chain commit $commit_before"
    return 0
  fi
  CHAIN_GIT_RELEASE_LEAF_DETAIL="$context no longer descends from launch chain commit $commit_before"
  return 1
}

# shellcheck disable=SC2034 # CHAIN_GIT_RELEASE_LEAF_DETAIL is consumed by callers.
chain_git_release_leaf_merge_commits_ok() {
  local issue_worktree="${1:?usage: chain_git_release_leaf_merge_commits_ok <issue-worktree> <commit-before> [context]}"
  local commit_before="${2:?commit before required}"
  local context="${3:-release-bearing leaf}"

  CHAIN_GIT_RELEASE_LEAF_DETAIL=""
  if ! git -C "$issue_worktree" cat-file -e "$commit_before^{commit}" 2>/dev/null; then
    CHAIN_GIT_RELEASE_LEAF_DETAIL="$context cannot resolve launch chain commit $commit_before"
    return 1
  fi
  if git -C "$issue_worktree" rev-list --merges "$commit_before..HEAD" 2>/dev/null | grep -q .; then
    CHAIN_GIT_RELEASE_LEAF_DETAIL="$context contains merge commits after launch chain commit $commit_before"
    return 1
  fi
  CHAIN_GIT_RELEASE_LEAF_DETAIL="$context has no merge commits after launch chain commit $commit_before"
  return 0
}

chain_git_integrate_issue_workspace() {
  local repo_root="${1:?usage: chain_git_integrate_issue_workspace <repo-root> <chain-worktree> <chain-branch> <issue-worktree> <issue-branch> <strategy> [sync-strategy]}"
  local chain_worktree="${2:?chain worktree required}"
  local chain_branch="${3:?chain branch required}"
  local issue_worktree="${4:?issue worktree required}"
  local issue_branch="${5:?issue branch required}"
  local strategy="${6:?git metadata strategy required}"
  local sync_strategy="${7:-rebase}"

  case "$sync_strategy" in
    rebase|squash) ;;
    *)
      printf 'chain-git: unknown issue sync strategy: %s\n' "$sync_strategy" >&2
      return 2
      ;;
  esac

  case "$strategy" in
    linked-worktree)
      case "$sync_strategy" in
        rebase)
          git -C "$issue_worktree" rebase "$chain_branch" || return 1
          git -C "$chain_worktree" merge --ff-only "$issue_branch" || return 1
          ;;
        squash)
          git -C "$chain_worktree" merge --squash "$issue_branch" || return 1
          git -C "$chain_worktree" commit -m "Squash $issue_branch into $chain_branch" || return 1
          ;;
      esac
      git -C "$repo_root" worktree remove "$issue_worktree" || return 1
      git -C "$repo_root" branch -D "$issue_branch" || return 1
      ;;
    local-clone)
      case "$sync_strategy" in
        rebase)
          git -C "$issue_worktree" fetch "$chain_worktree" "$chain_branch" || return 1
          git -C "$issue_worktree" rebase FETCH_HEAD || return 1
          git -C "$chain_worktree" fetch "$issue_worktree" "$issue_branch" || return 1
          git -C "$chain_worktree" merge --ff-only FETCH_HEAD || return 1
          ;;
        squash)
          git -C "$chain_worktree" fetch "$issue_worktree" "$issue_branch" || return 1
          git -C "$chain_worktree" merge --squash FETCH_HEAD || return 1
          git -C "$chain_worktree" commit -m "Squash $issue_branch into $chain_branch" || return 1
          ;;
      esac
      rm -rf "$issue_worktree" || return 1
      ;;
    *)
      printf 'chain-git: unknown git metadata strategy: %s\n' "$strategy" >&2
      return 2
      ;;
  esac
}

chain_git_parent_finalize_summary_eligible() {
  local summary_file="${1:?usage: chain_git_parent_finalize_summary_eligible <summary-file>}"
  [ -f "$summary_file" ] || return 1
  jq -e '
    def text($v):
      if $v == null then ""
      elif ($v | type) == "array" then ($v | map(tostring) | join("\n"))
      elif ($v | type) == "object" then ($v | tojson)
      else ($v | tostring)
      end;
    def checks: ((.tests // []) + (.lints // []) + (.builds // []));
    def clean_outcome($v):
      (($v.outcome // $v.status // "") | ascii_downcase)
      | sub(":.*$"; "")
      | test("^(pass|passed|passed_with_warning|passed_before_alternate_commit|ok|success|succeeded|skipped)$");
    def check_note($v):
      [($v.command // ""), ($v.outcome // $v.status // ""), ($v.warning // ""), ($v.notes // "")]
      | map(tostring)
      | join(" ");
    def primary_commit_after:
      (.commit_or_pr_references.commit_after // .primary_commit_after // .primary_git_commit_after // "");
    def alternate_metadata_note:
      (text(.blocked_reason) + "\n" + text(.carryover) + "\n" + text(.lessons))
      | ascii_downcase
      | test("alternate|copied git|writable copied|\\.git\\.codex|primary metadata|primary \\.git|original \\.git|primary.*head.*remain");
    def no_primary_commit:
      ((.commit_after // null) == null or (.commit_after // "") == "" or (.commit_after == .commit_before))
      or (primary_commit_after == .commit_before and alternate_metadata_note);
    def unsafe_parent_finalize_note:
      ascii_downcase as $line
      | (($line | test("destructive|unrelated issue|scope cannot|review failed"))
         or (($line | test("secret"))
             and (($line | test("w_argus_secret_scope|secret-scope|secret_scope")) | not)));
    (((.status // "") | ascii_downcase) | test("^(blocked|failed)$"))
    and no_primary_commit
    and ((.blocked_reason // "") | ascii_downcase
      | (test("git|\\.git|index\\.lock|stage|staging|commit")
         and test("operation not permitted|permission denied|unwritable|not writable|denies writes|cannot write|failed creating")))
    and all((((text(.carryover) + "\n" + text(.lessons)) | split("\n")) + [checks[]? | check_note(.)])[]?; (unsafe_parent_finalize_note | not))
    and ((checks | length) > 0)
    and all(checks[]; clean_outcome(.))
  ' "$summary_file" >/dev/null 2>&1
}

chain_git_parent_finalize_summary_reports_failure() {
  local summary_file="${1:?usage: chain_git_parent_finalize_summary_reports_failure <summary-file>}"
  [ -f "$summary_file" ] || return 1
  jq -e '
    (((.exit_code // 0) | tonumber? // 0) != 0)
    or (((.status // "") | ascii_downcase) | test("^(blocked|failed)$"))
  ' "$summary_file" >/dev/null 2>&1
}

chain_git_parent_finalize_effective_worker_rc() {
  local worker_rc="${1:?usage: chain_git_parent_finalize_effective_worker_rc <worker-rc> <summary-file>}"
  local summary_file="${2:?summary file required}" summary_rc
  if [ "$worker_rc" -ne 0 ]; then
    printf '%s\n' "$worker_rc"
    return 0
  fi
  summary_rc=$(jq -r '((.exit_code // 0) | tonumber? // 0)' "$summary_file" 2>/dev/null || printf '0')
  if [ "$summary_rc" -ne 0 ] 2>/dev/null; then
    printf '%s\n' "$summary_rc"
    return 0
  fi
  if chain_git_parent_finalize_summary_reports_failure "$summary_file"; then
    printf '1\n'
    return 0
  fi
  printf '0\n'
}

chain_git_parent_finalize_reconciled_worker_rc() {
  local worker_rc="${1:?usage: chain_git_parent_finalize_reconciled_worker_rc <worker-rc> <effective-worker-rc> <parent-finalized>}"
  local effective_worker_rc="${2:?effective worker rc required}"
  local parent_finalized="${3:-false}"
  if [ "$parent_finalized" = true ]; then
    printf '0\n'
    return 0
  fi
  if [ "$worker_rc" -eq 0 ] && [ "$effective_worker_rc" -ne 0 ]; then
    printf '%s\n' "$effective_worker_rc"
    return 0
  fi
  printf '%s\n' "$worker_rc"
}

chain_git_parent_finalize_has_public_diff() {
  local issue_worktree="${1:?usage: chain_git_parent_finalize_has_public_diff <issue-worktree>}"
  git -C "$issue_worktree" status --porcelain --untracked-files=all -- \
    . \
    ':!.studio' ':!.studio/**' \
    ':!.git[0-9]*' ':!.git[0-9]*/**' \
    ':!.git-*' ':!.git-*/**' \
    | grep -q .
}

chain_git_valid_change_type() {
  case "${1:-}" in
    feature|bugfix-shipped|bugfix-wip|regression-fix|refactor|docs|test|chore|release) return 0 ;;
    *) return 1 ;;
  esac
}

chain_git_parent_finalize_issue_commit() {
  local issue_worktree="${1:?usage: chain_git_parent_finalize_issue_commit <issue-worktree> <issue-number> <summary-file> [host] }"
  local issue="${2:?issue number required}"
  local summary_file="${3:?summary file required}"
  local host="${4:-}"
  local issue_title subject change_type affected_areas problem solution changelog implementation_notes caveats

  chain_git_parent_finalize_summary_eligible "$summary_file" || return 1
  chain_git_parent_finalize_has_public_diff "$issue_worktree" || return 1
  issue_title=$(jq -r '.issue_title // empty' "$summary_file" 2>/dev/null || true)
  change_type=$(jq -r '.change_type // .commit_change_type // .commit_metadata.change_type // .commit_trailers.change_type // empty' "$summary_file" 2>/dev/null || true)
  if ! chain_git_valid_change_type "$change_type"; then
    printf 'chain-git: parent finalize refusing commit without valid summary change_type trailer value\n' >&2
    return 1
  fi
  if [ -z "$host" ] || [ "$host" = "unknown" ]; then
    host=$(jq -r '.host // .worker_host // empty' "$summary_file" 2>/dev/null || true)
  fi
  if [ -z "$host" ] || [ "$host" = "unknown" ]; then
    printf 'chain-git: parent finalize refusing commit without known worker host\n' >&2
    return 1
  fi
  affected_areas=$(jq -r '.affected_areas // .commit_affected_areas // .commit_metadata.affected_areas // empty' "$summary_file" 2>/dev/null || true)
  problem=$(jq -r '.problem // .commit_problem // .commit_metadata.problem // empty' "$summary_file" 2>/dev/null || true)
  solution=$(jq -r '.solution // .commit_solution // .commit_metadata.solution // empty' "$summary_file" 2>/dev/null || true)
  changelog=$(jq -r '.changelog // .commit_changelog // .commit_metadata.changelog // empty' "$summary_file" 2>/dev/null || true)
  implementation_notes=$(jq -r '.implementation_notes // .commit_implementation_notes // .commit_metadata.implementation_notes // empty' "$summary_file" 2>/dev/null || true)
  caveats=$(jq -r '.caveats // .commit_caveats // .commit_metadata.caveats // empty' "$summary_file" 2>/dev/null || true)
  if [ -z "$affected_areas" ] || [ -z "$problem" ] || [ -z "$solution" ] || [ -z "$changelog" ] || [ -z "$implementation_notes" ] || [ -z "$caveats" ]; then
    printf 'chain-git: parent finalize refusing commit without complete structured commit summary fields\n' >&2
    return 1
  fi

  git -C "$issue_worktree" reset -q -- .studio '.git[0-9]*' '.git-*' 2>/dev/null || true
  rm -rf "$issue_worktree/.studio"
  git -C "$issue_worktree" add --all -- \
    . \
    ':!.studio' ':!.studio/**' \
    ':!.git[0-9]*' ':!.git[0-9]*/**' \
    ':!.git-*' ':!.git-*/**'

  if git -C "$issue_worktree" diff --cached --quiet --exit-code; then
    return 1
  fi
  git -C "$issue_worktree" diff --cached --check
  if git -C "$issue_worktree" diff --cached --name-only | grep -Eq '^(\.studio(/|$)|\.git[0-9][^/]*(/|$)|\.git-[^/]*(/|$))'; then
    git -C "$issue_worktree" reset -q -- .studio '.git[0-9]*' '.git-*' 2>/dev/null || true
    return 1
  fi

  if [ -n "$issue_title" ]; then
    subject="$change_type: $issue_title (#$issue)"
  else
    subject="$change_type: implement #$issue"
  fi
  case "$host" in
    codex|codex-*|*codex*)
      STUDIO_HOST="$host" git -C "$issue_worktree" commit \
        -m "$subject" \
        -m "Affected-Areas: $affected_areas" \
        -m "Problem: $problem" \
        -m "Solution: $solution" \
        -m "Changelog: $changelog" \
        -m "Implementation notes: $implementation_notes" \
        -m "Caveats: $caveats" \
        -m "Closes #$issue" \
        -m "Change-Type: $change_type" \
        -m "Studio-Host: $host" \
        -m "Co-authored-by: Codex <noreply@openai.com>"
      ;;
    *)
      STUDIO_HOST="$host" git -C "$issue_worktree" commit \
        -m "$subject" \
        -m "Affected-Areas: $affected_areas" \
        -m "Problem: $problem" \
        -m "Solution: $solution" \
        -m "Changelog: $changelog" \
        -m "Implementation notes: $implementation_notes" \
        -m "Caveats: $caveats" \
        -m "Closes #$issue" \
        -m "Change-Type: $change_type" \
        -m "Studio-Host: $host"
      ;;
  esac
}

chain_git_parent_finalize_event_payload() {
  local summary_file="${1:?usage: chain_git_parent_finalize_event_payload <summary> <before> <after> <host>}"
  local before="${2:?before commit required}"
  local after="${3:?after commit required}"
  local host="${4:?host required}"
  jq -cn \
    --arg summary "$summary_file" \
    --arg before "$before" \
    --arg after "$after" \
    --arg host "$host" \
    --arg reason "worker_git_metadata_unwritable" \
    '{summary:$summary, commit_before:$before, commit_after:$after, worker_host:$host, reason:$reason}'
}
