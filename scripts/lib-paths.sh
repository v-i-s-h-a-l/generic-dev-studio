#!/usr/bin/env bash
# lib-paths.sh — sourced by every fleet script.
#
# Exposes:
#   resolve_project          prints the project slug (or errors out)
#   resolve_display_name     prints a friendly display name (git remote → slug)
#   resolve_inbox_root       prints the current project's achilles-inbox root
#   resolve_inbox_root_for   prints the achilles-inbox root for a given slug
#   resolve_feedback_inbox_for prints the studio-self feedback inbox for a source slug
#   resolve_feedback_inbox_root prints the studio-self feedback inbox root
#   resolve_analysis_root    prints the studio-self private analysis root
#   resolve_runtime_global   prints the machine-global runtime root
#   resolve_push_queue       prints the per-project push-queue path
#   detect_stack             prints ios|web|rust|python|go|mixed|unknown
#   list_fleet_projects      prints every project with an active fleet
#   mtime                    cross-platform file mtime (stat -f %m / -c %Y)
#   yaml_parse_check         loud YAML parse gate (stderr + event on failure)
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
#   resolve_events_dir       events/ root for the current project
#   resolve_events_dir_for   events/ root for a given slug
#   resolve_event_log        today's events/<YYYY-MM-DD>.jsonl
#   resolve_auto_sweep_state per-project auto-sweep backoff state file
#   resolve_derived_data_for per-worktree Xcode DerivedData root (machine-global)
#   resolve_waive_dir        review-waive state dir for the current project
#   resolve_waive_dir_for    review-waive state dir for a given slug
#   resolve_waive_file       review-waive state file for current project + gate
#   resolve_waive_file_for   review-waive state file for a given slug + gate
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

# Audit-report root — where studio-audit.sh writes persisted findings in
# --report mode. Private per-project artifacts; never committed.
resolve_audit_root() {
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/audit"
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
#
# LEGACY ROOT. Under ~/.claude/, outside the studio's ~/.dev-studio/ allowlist.
# Kept only for legacy readers (migrate-ledger consolidating pre-2.6 events,
# Claude Code's own auto-managed memory). New runtime writes must go under
# ~/.dev-studio/<project>/ via resolve_events_dir / resolve_project_root_for.
resolve_project_memory() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  local slug="${top//\//-}"
  printf '%s\n' "$HOME/.claude/projects/${slug}/memory"
}

# Per-project events dir — post-2.6 canonical location for the day-partitioned
# event log (~/.dev-studio/<project>/events/). Both writers (append_event) and
# readers (read-events.sh, budget-report.sh, chanakya-snap.sh) resolve here.
resolve_events_dir_for() {
  local project="${1:?usage: resolve_events_dir_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/events"
}

resolve_events_dir() {
  local project
  project=$(resolve_project) || return 1
  resolve_events_dir_for "$project"
}

resolve_event_log() {
  local dir
  dir=$(resolve_events_dir) || return 1
  printf '%s\n' "$dir/$(date -u +%Y-%m-%d).jsonl"
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
  local events_dir f
  events_dir=$(resolve_events_dir) || return 1
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

# Per-session start-timestamp scratch file. Stamped at session boot
# (emit-agent-boot.sh) with epoch seconds, consumed at session completion
# (emit-agent-session-completed.sh) to compute duration_s. Co-located with
# agent-boot's sentinel directory so one session has one place for its scratch.
#
# Why a scratch file, not the dispatch event: session start is earlier than
# dispatch on waive/direct/rescue paths. Stamping at the unconditional
# first-write hook (agent-boot) is the one place every path passes through.
resolve_session_start_stamp() {
  local session_id="${1:?usage: resolve_session_start_stamp <session-id>}"
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/sessions/${session_id}.start"
}

# Auto-sweep backoff state — persists the next-sweep delay computed by
# scripts/sweep-adaptive-backoff.sh so subsequent sweeps honor the backoff.
resolve_auto_sweep_state() {
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/auto_sweep_state.md"
}

# Review-waive state file for a given project + gate. Captures a structured
# pause of a review gate (e.g. argus) — reason, started_at, sunset_trigger,
# accumulated_count. See _shared/contracts/events.md `review_pending` row.
# Path is per-project (waives don't cross projects).
resolve_waive_dir_for() {
  local project="${1:?usage: resolve_waive_dir_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/state/waives"
}

resolve_waive_dir() {
  local project
  project=$(resolve_project) || return 1
  resolve_waive_dir_for "$project"
}

resolve_waive_file_for() {
  local project="${1:?usage: resolve_waive_file_for <slug> <gate>}"
  local gate="${2:?usage: resolve_waive_file_for <slug> <gate>}"
  printf '%s\n' "$(resolve_waive_dir_for "$project")/$gate.yaml"
}

resolve_waive_file() {
  local gate="${1:?usage: resolve_waive_file <gate>}"
  local project
  project=$(resolve_project) || return 1
  resolve_waive_file_for "$project" "$gate"
}

# True iff a structured waive file exists for <gate> in the current project.
# Presence = active; the schema has no expiry field (sunset_trigger is a
# free-text predicate evaluated by humans / higher layers). Callers use this
# to suppress reminder events while a waive is live.
is_waive_active() {
  local gate="${1:?usage: is_waive_active <gate>}"
  local f
  f=$(resolve_waive_file "$gate" 2>/dev/null) || return 1
  [ -f "$f" ]
}

# True iff <branch-name> is a policy-protected integration branch — one that
# advances only via review (human, Argus, external-agent PR). Used by
# sweep-ingest's ungated-merge audit (#108) to gate post-fact warning events.
# The set is small and repo-conventional; extend here when a new release-line
# convention lands rather than scattering branch-pattern checks across callers.
is_protected_branch() {
  local name="${1:-}"
  [ -z "$name" ] && return 1
  case "$name" in
    main|master|trunk|develop) return 0 ;;
    release/*|releases/*|v/*|hotfix/*) return 0 ;;
    *) return 1 ;;
  esac
}

# DerivedData root for a given worktree slug. Xcode per-worker isolation —
# each worker's xcodebuild run points DerivedDataPath at this dir to prevent
# index contention across parallel workers.
resolve_derived_data_for() {
  local worktree_slug="${1:?usage: resolve_derived_data_for <worktree-slug>}"
  printf '%s\n' "$HOME/.dev-studio/.runtime/derived-data/$worktree_slug"
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
  printf '%s\n' "$(resolve_feedback_inbox_root)/$project"
}

# Root of the studio-self feedback inbox (parent of per-source subfolders).
resolve_feedback_inbox_root() {
  printf '%s\n' "$(resolve_project_root_for generic-dev-studio)/feedback-inbox"
}

# Studio-self analysis root — private, never-committed reports (see CLAUDE.md
# "Analysis sessions and privacy" → "Detailed analysis report").
resolve_analysis_root() {
  printf '%s\n' "$(resolve_project_root_for generic-dev-studio)/analysis"
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

# Parse-check a YAML file loud. yq's `// default` fallback masks parse errors —
# callers reading `.state // "emitted"` get "emitted" from a malformed file
# just as they do from a valid one that omits the key. Use this before any
# trust-bearing read so broken YAML surfaces as a signal instead of silently
# defaulting through. Returns 0 on success; non-zero + stderr + event on fail.
#
#   caller: short tag embedded in the event so downstream readers know where
#           the parse error surfaced from (e.g. "sweep-enumerate").
yaml_parse_check() {
  local f="${1:?usage: yaml_parse_check <file> [caller]}" caller="${2:-unknown}"
  [ -f "$f" ] || return 2
  command -v yq >/dev/null 2>&1 || return 0

  # #156 — quarantine fast-skip. If a file failed to parse on a prior sweep
  # AND its mtime hasn't moved since, treat it as still-broken: skip the
  # parse attempt and the noisy debrief_parse_error emit. Auto-clears as
  # soon as the user touches the file. Quarantine is a JSONL append-only
  # log so multiple sweeps converging is safe; the `tail -1` lookup wins.
  local q_path q_entry q_mtime now_mtime
  q_path=$(_quarantine_path) || q_path=""
  if [ -n "$q_path" ] && [ -f "$q_path" ]; then
    q_entry=$(grep -F "\"path\":\"$f\"" "$q_path" 2>/dev/null | tail -1)
    if [ -n "$q_entry" ]; then
      q_mtime=$(printf '%s' "$q_entry" | sed -n 's/.*"mtime":\([0-9]*\).*/\1/p')
      now_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
      if [ -n "$q_mtime" ] && [ "$q_mtime" = "$now_mtime" ]; then
        return 2  # still-quarantined; no event, no work
      fi
    fi
  fi

  local err
  if err=$(yq 'length' "$f" 2>&1 >/dev/null); then
    return 0
  fi
  printf 'yaml_parse_check: %s: %s\n' "$f" "$err" >&2
  # Best-effort escape for JSON — collapse backslash/quote/tab/newline so the
  # event line stays well-formed even when yq's error includes multiline diags.
  local esc
  esc=$(printf '%s' "$err" | head -c 300 | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g' | tr '\n' ' ')
  append_event chanakya debrief_parse_error "" \
    "{\"path\":\"$f\",\"yq_error\":\"$esc\",\"caller\":\"$caller\"}" \
    2>/dev/null || true

  # Append to the quarantine list so the next sweep skips this file unless
  # its mtime advances. Best-effort — quarantine is a perf optimization,
  # not a correctness gate.
  if [ -n "$q_path" ]; then
    local fp_mtime ts
    fp_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    mkdir -p "$(dirname "$q_path")" 2>/dev/null || true
    printf '{"path":"%s","mtime":%s,"caller":"%s","ts":"%s"}\n' \
      "$f" "$fp_mtime" "$caller" "$ts" >> "$q_path" 2>/dev/null || true
  fi
  return 2
}

# #156 — resolves the per-project debrief quarantine file path. Stays under
# ~/.dev-studio/<project>/.runtime/state/ to inherit existing path allowlist
# (REVIEW.md R1) and per-project isolation (R4).
_quarantine_path() {
  local project
  project=$(resolve_project 2>/dev/null) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/debrief-quarantine.jsonl"
}

# #215 — self-node identity. The node registry can include an entry that
# points at the current machine; node-pick / node-health / node-dispatch
# must recognize that case and run inline rather than over SSH. The
# discriminator is `machine_id` (set by scripts/machine-id.sh on bootstrap),
# never `host` — hostnames change, machine-id files don't.
#
# Synthetic id `local` always tests as self (preserves pre-#215 behaviour
# where `local` is the not-registered fallback).

resolve_self_machine_id() {
  local mid_script
  mid_script="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/machine-id.sh"
  if [ -x "$mid_script" ]; then
    "$mid_script" 2>/dev/null
    return 0
  fi
  local id_file="$HOME/.dev-studio/.runtime/machine-id"
  [ -r "$id_file" ] && tr -d '[:space:]' < "$id_file"
}

node_machine_id_for() {
  local id="$1" registry
  [ -n "$id" ] || return 1
  registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg id "$id" '.nodes[]? | select(.id == $id) | .machine_id // empty' \
    "$registry" 2>/dev/null
}

# Returns 0 if <id> refers to this machine. `local` is always self.
# Any registered entry whose machine_id matches self's machine_id is self.
# Unknown ids and registry-less hosts return 1 (not self).
node_is_self() {
  local id="$1"
  [ -n "$id" ] || return 1
  [ "$id" = "local" ] && return 0
  local self mid
  self=$(resolve_self_machine_id)
  [ -n "$self" ] || return 1
  mid=$(node_machine_id_for "$id")
  [ -n "$mid" ] && [ "$mid" = "$self" ]
}

# #215 — gate UX surface. Three side-channels that surface the live
# build/test dispatch state to the user:
#   1. stderr banner    — visible inline in the agent's terminal
#   2. iTerm2 badge     — translucent corner overlay, persists through scroll
#   3. terminal title   — alt-tab / pane / dock visibility
# All three are suppressed under STUDIO_GATE_QUIET=1 so scripted callers
# (tests, batch jobs) don't accumulate noise. The escapes are best-effort:
# non-supporting terminals discard them silently.

gate_announce_start() {
  [ "${STUDIO_GATE_QUIET:-0}" = "1" ] && return 0
  local action="$1" node="$2" task="$3" mode="$4"
  printf '→ %s: node=%s  task=%s  mode=%s\n' "$action" "$node" "$task" "$mode" >&2
  _gate_set_title "$action $task → $node"
  _gate_set_badge "$task" "→ $node" "$mode"
}

gate_announce_done() {
  [ "${STUDIO_GATE_QUIET:-0}" = "1" ] && return 0
  local action="$1" node="$2" task="$3" status="$4" dur="${5:-?}"
  printf '← %s: node=%s  task=%s  status=%s  wall=%ss\n' \
    "$action" "$node" "$task" "$status" "$dur" >&2
  _gate_set_title ""
  _gate_set_badge ""
}

# OSC 0 — sets both window and tab title on most modern terminals
# (Terminal.app, iTerm2, Alacritty, kitty, ghostty). Empty value clears.
_gate_set_title() {
  printf '\033]0;%s\007' "$1" >&2
}

# iTerm2 SetBadgeFormat — translucent corner overlay. Format string is
# base64-encoded UTF-8; literal newlines render as line breaks. Skipping
# the escape on non-iTerm terminals avoids the small chance of a stray
# OSC sequence bleeding through to a logger that captures stderr.
_gate_set_badge() {
  [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || return 0
  if [ -z "${1:-}${2:-}${3:-}" ]; then
    printf '\033]1337;SetBadgeFormat=\007' >&2
    return 0
  fi
  local content="${1:-}"
  [ -n "${2:-}" ] && content="$content"$'\n'"$2"
  [ -n "${3:-}" ] && content="$content"$'\n'"$3"
  local b64
  b64=$(printf '%s' "$content" | base64 | tr -d '\n')
  printf '\033]1337;SetBadgeFormat=%s\007' "$b64" >&2
}
