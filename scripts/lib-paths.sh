#!/usr/bin/env bash
# lib-paths.sh — sourced by every fleet script.
#
# Exposes:
#   resolve_project          prints the project slug (or errors out)
#   resolve_display_name     prints a friendly display name (git remote → slug)
#   resolve_inbox_root       prints the current project's achilles-inbox root
#   resolve_inbox_root_for   prints the achilles-inbox root for a given slug
#   resolve_feedback_inbox_for prints the studio-self feedback inbox for a source slug
#   resolve_runtime_global   prints the machine-global runtime root
#   resolve_push_queue       prints the per-project push-queue path
#   detect_stack             prints ios|web|rust|python|go|mixed|unknown
#   list_fleet_projects      prints every project with an active fleet
#   mtime                    cross-platform file mtime (stat -f %m / -c %Y)
#
# Post-2.6 canonical layout (see _shared/primitives/file-locations.md):
#   resolve_plans_dir        plans/ root for the current project
#   resolve_plans_dir_for    plans/ root for a given slug
#   resolve_tasks_dir_for    plans/tasks/
#   resolve_briefs_dir_for   plans/briefs/
#   resolve_debriefs_dir_for plans/debriefs/
#   resolve_reviews_dir_for  plans/reviews/
#   resolve_rounds_dir_for   plans/rounds/
#   resolve_releases_dir_for plans/releases/
#   resolve_feedback_dir_for plans/feedback/
#   resolve_crashes_dir_for  plans/crashes/
#   resolve_plans_index_for  plans/index.yaml
#
# DEPRECATED (Phase 2.6 cutover, 2026-04-22) — retained until the last caller
# upgrades to the YAML shape; see inline comments for removal criteria:
#   resolve_chanakya_inbox[_for] — legacy plans/chanakya-inbox/ (still holds
#                                  assets/ + *-tests.md + processed/)
#   resolve_briefs_dir           — legacy plans/chanakya-tasks/ (pre-migration briefs)
#
# Project resolution order:
#   1. ACHILLES_PROJECT env var (escape hatch for cross-project dispatch / testing)
#   2. basename of git rev-parse --show-toplevel (normal case)
#   3. fail with a helpful hint to stderr
#
# Root resolution order:
#   1. ACHILLES_INBOX_ROOT env var (explicit override — bypasses project resolution)
#   2. $HOME/.dev-studio/<project>/.runtime/achilles-inbox

# No `set -e` here — sourced into scripts that may or may not want strict mode.

resolve_project() {
  if [ -n "${ACHILLES_PROJECT:-}" ]; then
    printf '%s\n' "$ACHILLES_PROJECT"
    return 0
  fi
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    cat >&2 <<EOF
error: no project resolved.
  Either (a) run this from inside a git repo so \`git rev-parse --show-toplevel\`
  picks up the project name, or (b) set ACHILLES_PROJECT=<slug> explicitly
  (e.g. ACHILLES_PROJECT=turnip-ios).
EOF
    return 1
  }
  basename "$top"
}

resolve_inbox_root() {
  if [ -n "${ACHILLES_INBOX_ROOT:-}" ]; then
    printf '%s\n' "$ACHILLES_INBOX_ROOT"
    return 0
  fi
  local project
  project=$(resolve_project) || return 1
  resolve_inbox_root_for "$project"
}

# Build the inbox root for a specific project slug without running project
# resolution. Used by --all-projects loops to avoid re-forking git per project.
resolve_inbox_root_for() {
  local project="${1:?usage: resolve_inbox_root_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/achilles-inbox"
}

resolve_runtime_global() {
  printf '%s\n' "$HOME/.dev-studio/.runtime"
}

resolve_push_queue() {
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/push-queue.jsonl"
}

# Work-stealing dispatch queue — one ordered pending-task list per project.
# Chanakya enqueues tasks; drain hands them out one-by-one as workers free up.
resolve_dispatch_queue() {
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/dispatch-queue.jsonl"
}

# Project memory dir — Claude Code auto-manages one of these per repo. Slug is
# the repo toplevel path with `/` → `-` (leading slash included, so a repo at
# `/Users/x/work/foo` maps to `-Users-x-work-foo`).
# Read _shared/primitives/file-locations.md for the full scheme.
# Used by scripts that need to append to the shared event log.
resolve_project_memory() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  local slug="${top//\//-}"
  printf '%s\n' "$HOME/.claude/projects/${slug}/memory"
}

resolve_event_log() {
  local memory
  memory=$(resolve_project_memory) || return 1
  printf '%s\n' "$memory/events/$(date -u +%Y-%m-%d).jsonl"
}

# Append one JSONL event to today's event log. Caller provides agent, event,
# task id, and a pre-formatted JSON `data` object (default `{}`). Keep the
# entire line ≤ 4096 bytes so O_APPEND stays atomic (see _shared/contracts/events.md).
append_event() {
  local agent="${1:?append_event <agent> <event> <task> [data-json]}"
  local event="$2" task="${3:-}" data="${4:-\{\}}"
  local log ts
  log=$(resolve_event_log) || return 1
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","agent":"%s","event":"%s","task":"%s","data":%s}\n' \
    "$ts" "$agent" "$event" "$task" "$data" >> "$log"
}

# Print the ts of the most recent event matching {event, task} in the last
# N days of event logs (default 14). Empty output if nothing matches.
find_recent_event_ts() {
  local target_event="$1" target_task="$2" days="${3:-14}"
  local memory events_dir f
  memory=$(resolve_project_memory) || return 1
  events_dir="$memory/events"
  [ -d "$events_dir" ] || return 1
  # Filenames are YYYY-MM-DD.jsonl — lexicographic sort == date sort.
  ls -r "$events_dir"/*.jsonl 2>/dev/null | head -n "$days" | while IFS= read -r f; do
    grep "\"event\":\"$target_event\"" "$f" 2>/dev/null \
      | grep "\"task\":\"$target_task\"" \
      | tail -n 1 \
      | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p'
  done | head -n 1
}

# Portable ISO-8601-Z → epoch-seconds. macOS: stat-style -j; GNU: -d.
ts_to_epoch() {
  local ts="$1"
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null
}

# Emit pre-dispatch blind-spot signals (Step 0E3) for a task about to be
# routed. Fires `task_redispatched` if the task has a prior `task_completed`
# in recent history, and `task_awaiting_user_resolved` if a prior
# `task_awaiting_user` is newer than its last resolved event. Best-effort:
# failures are swallowed so the dispatch itself never breaks.
emit_predispatch_signals() {
  local task="${1:?emit_predispatch_signals <task-id>}"
  local ts_complete ts_await ts_resolved now_s await_s wait_s
  ts_complete=$(find_recent_event_ts task_completed "$task" 2>/dev/null)
  if [ -n "$ts_complete" ]; then
    append_event chanakya task_redispatched "$task" \
      "{\"prior_completed_at\":\"$ts_complete\",\"reason\":\"user_retry\"}" \
      2>/dev/null || true
  fi
  ts_await=$(find_recent_event_ts task_awaiting_user "$task" 2>/dev/null)
  if [ -n "$ts_await" ]; then
    ts_resolved=$(find_recent_event_ts task_awaiting_user_resolved "$task" 2>/dev/null)
    if [ -z "$ts_resolved" ] || [ "$ts_await" \> "$ts_resolved" ]; then
      now_s=$(date -u +%s)
      await_s=$(ts_to_epoch "$ts_await") || await_s=0
      wait_s=$(( now_s - await_s ))
      [ "$await_s" -eq 0 ] && wait_s=-1
      append_event chanakya task_awaiting_user_resolved "$task" \
        "{\"wait_duration_s\":$wait_s,\"resolved_by\":\"user_answered\"}" \
        2>/dev/null || true
    fi
  fi
}

# DEPRECATED (Phase 2.6 cutover, 2026-04-22): legacy chanakya-inbox root.
# Post-migration, debriefs live at plans/debriefs/<debrief-id>.yaml (use
# resolve_debriefs_dir_for). The directory itself is retained because
# chanakya-inbox/assets/ (Slack screenshots) and *-tests.md (test-case
# artifacts) were not in-scope for 2.6 migration; chanakya-inbox/processed/
# holds pre-migration debriefs archived-as-is per Q18. Remove these
# resolvers when scripts/detect-edits.sh and scripts/achilles-worker.sh
# upgrade to the YAML shape — tracked as a follow-up issue.
resolve_chanakya_inbox_for() {
  local project="${1:?usage: resolve_chanakya_inbox_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/plans/chanakya-inbox"
}

resolve_chanakya_inbox() {
  local project
  project=$(resolve_project) || return 1
  resolve_chanakya_inbox_for "$project"
}

# Plans dir for a given project — root of the post-2.6 canonical layout.
# Callers typically glob plans/tasks/*.yaml, plans/briefs/*.yaml, etc., or
# (preferred) go through scripts/query-plans.sh --kind=<kind>.
resolve_plans_dir_for() {
  local project="${1:?usage: resolve_plans_dir_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/plans"
}

resolve_plans_dir() {
  local project
  project=$(resolve_project) || return 1
  resolve_plans_dir_for "$project"
}

# Per-kind convenience resolvers for the post-2.6 YAML layout. These return
# the directory; caller globs *.yaml or queries via query-plans.sh.
resolve_tasks_dir_for()    { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/tasks"; }
resolve_briefs_dir_for()   { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/briefs"; }
resolve_debriefs_dir_for() { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/debriefs"; }
resolve_reviews_dir_for()  { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/reviews"; }
resolve_rounds_dir_for()   { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/rounds"; }
resolve_releases_dir_for() { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/releases"; }
resolve_feedback_dir_for() { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/feedback"; }
resolve_crashes_dir_for()  { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/crashes"; }
resolve_plans_index_for()  { printf '%s\n' "$(resolve_plans_dir_for    "${1:?slug}")/index.yaml"; }

# Per-project workspace root — where plans/, worktrees/, locks/, .runtime/ live.
resolve_project_root_for() {
  local project="${1:?usage: resolve_project_root_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project"
}

resolve_project_root() {
  local project
  project=$(resolve_project) || return 1
  resolve_project_root_for "$project"
}

# Studio-self feedback inbox for a given source-project slug. Feedback records
# authored in any project route here (see CLAUDE.md "Analysis sessions and
# privacy"); generic-dev-studio is the destination because that's where the
# studio's own issues and improvements get filed.
resolve_feedback_inbox_for() {
  local project="${1:?usage: resolve_feedback_inbox_for <source-slug>}"
  printf '%s\n' "$HOME/.dev-studio/generic-dev-studio/feedback-inbox/$project"
}

# DEPRECATED (Phase 2.6 cutover, 2026-04-22): legacy briefs dir.
# Post-migration, briefs live at plans/briefs/<brief-id>.yaml (use
# resolve_briefs_dir_for or scripts/query-plans.sh --kind=brief).
# This returns the pre-migration path because scripts/detect-edits.sh
# still scans it for brief-mtime diffs against preserved-legacy artifacts.
# Remove when the last caller upgrades to the YAML shape.
resolve_briefs_dir() {
  local project root
  project=$(resolve_project) || return 1
  root=$(resolve_project_root_for "$project")
  printf '%s\n' "$root/plans/chanakya-tasks"
}

# Friendly display name. Auto-derived in this order:
#   1. ACHILLES_DISPLAY_NAME env var (explicit override)
#   2. ~/.dev-studio/<project>/.display_name (pre-baked per-project override —
#      first non-empty, non-comment line; lets users pin a name without shell config)
#   3. basename of `git remote get-url origin` minus .git (e.g., turnip-ios from
#      git@github.com:Turnip-gg/turnip-ios.git — cleaner than the local dir name)
#   4. resolve_project slug (final fallback)
# Falls through silently; never errors — callers can use the slug directly.
resolve_display_name() {
  if [ -n "${ACHILLES_DISPLAY_NAME:-}" ]; then
    printf '%s\n' "$ACHILLES_DISPLAY_NAME"
    return 0
  fi
  local project pinfile name
  project=$(resolve_project 2>/dev/null) || project=""
  if [ -n "$project" ]; then
    pinfile="$HOME/.dev-studio/$project/.display_name"
    if [ -r "$pinfile" ]; then
      name=$(grep -v -E '^\s*(#|$)' "$pinfile" 2>/dev/null | head -n 1 | tr -d '[:space:]')
      if [ -n "$name" ]; then
        printf '%s\n' "$name"
        return 0
      fi
    fi
  fi
  local url
  url=$(git remote get-url origin 2>/dev/null) || url=""
  if [ -n "$url" ]; then
    name=$(basename "$url" .git 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "$url" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  [ -n "$project" ] && { printf '%s\n' "$project"; return 0; }
  echo "(unknown)"
}

# Detect the project's tech stack from filesystem fingerprints at the git
# toplevel. Pure read, no side effects. Output: one of
#   ios | web | rust | python | go | mixed | unknown
detect_stack() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "unknown"; return 0; }
  # Accumulate newline-separated hits so we don't depend on word-splitting
  # (word-splitting an unquoted var behaves differently in bash vs zsh).
  local hits=""
  if find "$top" -maxdepth 2 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) \
      -print -quit 2>/dev/null | grep -q .; then
    hits="${hits}ios"$'\n'
  fi
  [ -f "$top/package.json" ]   && hits="${hits}web"$'\n'
  [ -f "$top/Cargo.toml" ]     && hits="${hits}rust"$'\n'
  [ -f "$top/pyproject.toml" ] && hits="${hits}python"$'\n'
  [ -f "$top/setup.py" ]       && hits="${hits}python"$'\n'
  [ -f "$top/go.mod" ]         && hits="${hits}go"$'\n'
  local unique count
  unique=$(printf '%s' "$hits" | sort -u | sed '/^$/d')
  count=$(printf '%s\n' "$unique" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$count" in
    0) echo "unknown" ;;
    1) echo "$unique" ;;
    *) echo "mixed" ;;
  esac
}

# List every project that has a .runtime/achilles-inbox dir. One slug per line.
# Used by --all-projects flags.
list_fleet_projects() {
  local base="$HOME/.dev-studio"
  [ -d "$base" ] || return 0
  shopt -s nullglob
  for d in "$base"/*/.runtime/achilles-inbox; do
    # Strip $base/ prefix and everything from the first / onward to get the
    # project slug. Pure parameter expansion — no subshell forks.
    local project="${d#$base/}"
    project="${project%%/*}"
    # Skip the machine-global .runtime dir (matches the glob because it too
    # contains an achilles-inbox, historically; but it isn't a project).
    [ "$project" = ".runtime" ] && continue
    printf '%s\n' "$project"
  done
  shopt -u nullglob
}

# Portable file mtime (epoch seconds). macOS uses stat -f, GNU uses stat -c.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
