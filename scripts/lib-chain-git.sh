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
      git -C "$repo_root" worktree remove --force "$issue_worktree" 2>/dev/null || rm -rf "$issue_worktree"
      git -C "$repo_root" worktree add -B "$issue_branch" "$issue_worktree" "$chain_branch"
      ;;
    local-clone)
      rm -rf "$issue_worktree"
      git clone --quiet --no-local --branch "$chain_branch" "$chain_worktree" "$issue_worktree"
      git -C "$issue_worktree" checkout -q -B "$issue_branch" "$chain_branch"
      ;;
    *)
      printf 'chain-git: unknown git metadata strategy: %s\n' "$strategy" >&2
      return 2
      ;;
  esac
}

chain_git_integrate_issue_workspace() {
  local repo_root="${1:?usage: chain_git_integrate_issue_workspace <repo-root> <chain-worktree> <chain-branch> <issue-worktree> <issue-branch> <strategy>}"
  local chain_worktree="${2:?chain worktree required}"
  local chain_branch="${3:?chain branch required}"
  local issue_worktree="${4:?issue worktree required}"
  local issue_branch="${5:?issue branch required}"
  local strategy="${6:?git metadata strategy required}"

  case "$strategy" in
    linked-worktree)
      git -C "$issue_worktree" rebase "$chain_branch"
      git -C "$chain_worktree" merge --ff-only "$issue_branch"
      git -C "$repo_root" worktree remove "$issue_worktree"
      git -C "$repo_root" branch -D "$issue_branch"
      ;;
    local-clone)
      git -C "$issue_worktree" fetch "$chain_worktree" "$chain_branch"
      git -C "$issue_worktree" rebase FETCH_HEAD
      git -C "$chain_worktree" fetch "$issue_worktree" "$issue_branch"
      git -C "$chain_worktree" merge --ff-only FETCH_HEAD
      rm -rf "$issue_worktree"
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
      | test("^(pass|passed|passed_with_warning|passed_before_alternate_commit|ok|success|succeeded|skipped)$");
    def unsafe_parent_finalize_note:
      ascii_downcase as $line
      | (($line | test("destructive|unrelated issue|scope cannot|review failed"))
         or (($line | test("secret"))
             and (($line | test("w_argus_secret_scope|secret-scope|secret_scope")) | not)));
    (((.status // "") | ascii_downcase) | test("^(blocked|failed)$"))
    and ((.commit_after // null) == null or (.commit_after // "") == "" or (.commit_after == .commit_before))
    and ((.blocked_reason // "") | ascii_downcase
      | (test("git|\\.git|index\\.lock|stage|staging|commit")
         and test("operation not permitted|permission denied|unwritable|denies writes|cannot write|failed creating")))
    and all(((text(.carryover) + "\n" + text(.lessons)) | split("\n")[]?); (unsafe_parent_finalize_note | not))
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

chain_git_parent_finalize_has_public_diff() {
  local issue_worktree="${1:?usage: chain_git_parent_finalize_has_public_diff <issue-worktree>}"
  git -C "$issue_worktree" status --porcelain --untracked-files=all -- \
    . \
    ':!.studio' ':!.studio/**' \
    ':!.git[0-9]*' ':!.git[0-9]*/**' \
    ':!.git-*' ':!.git-*/**' \
    | grep -q .
}

chain_git_parent_finalize_issue_commit() {
  local issue_worktree="${1:?usage: chain_git_parent_finalize_issue_commit <issue-worktree> <issue-number> <summary-file>}"
  local issue="${2:?issue number required}"
  local summary_file="${3:?summary file required}"
  local issue_title subject

  chain_git_parent_finalize_summary_eligible "$summary_file" || return 1
  chain_git_parent_finalize_has_public_diff "$issue_worktree" || return 1
  issue_title=$(jq -r '.issue_title // empty' "$summary_file" 2>/dev/null || true)

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
    subject="$issue_title (#$issue)"
  else
    subject="Implement #$issue"
  fi
  git -C "$issue_worktree" commit -m "$subject" -m "Closes #$issue"
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
