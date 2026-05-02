#!/usr/bin/env bash
# studio-chain-runner.sh - execute issue chains with capacity-scaled fresh host sessions.
#
# Usage:
#   scripts/studio-chain-runner.sh <manifest|chain-name> [--only <chain>] [--host <host>] [--dry-run]
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

# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

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

command -v yq >/dev/null 2>&1 || { printf 'studio-chain-runner: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { printf 'studio-chain-runner: gh required\n' >&2; exit 2; }

REPO_SLUG="v-i-s-h-a-l/generic-dev-studio"
RUN_ROOT="${TMPDIR:-/tmp}/studio-chain-runner"
mkdir -p "$RUN_ROOT"
FINAL_PR_URL=""
RUN_ID=$(mint_uuidv7)
RUN_STARTED_AT=$(date -u +%s)
RUN_STARTED_TS=$(iso_ts_now)
RUN_STATUS="completed"
RUN_FAILURE_REASON=""
RUN_FINISHED=0
STUDIO_PROJECT_ROOT=$(resolve_project_root_for generic-dev-studio)
CHAIN_RUN_ROOT="$STUDIO_PROJECT_ROOT/chain-runs/$RUN_ID"
SUMMARY_ROOT="$CHAIN_RUN_ROOT/worker-summaries"
EVENTS_JSONL="$CHAIN_RUN_ROOT/events.jsonl"
RUN_STATE_JSON="$CHAIN_RUN_ROOT/state.json"
RUN_REPORT="$CHAIN_RUN_ROOT/report.md"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$SUMMARY_ROOT"
else
  EVENTS_JSONL="/dev/null"
fi

log() {
  printf 'studio-chain-runner: %s\n' "$*" >&2
}

now_epoch() {
  date -u +%s
}

duration_since() {
  local started="$1" ended="${2:-}"
  [ -z "$ended" ] && ended=$(now_epoch)
  printf '%s\n' "$(( ended - started ))"
}

event_data() {
  local event="$1" run_id="$2" chain_run_id="$3" issue_run_id="$4" status="$5" duration_s="${6:-null}" extra="${7:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn \
    --arg run_id "$run_id" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg manifest "$MANIFEST" \
    --arg status "$status" \
    --argjson duration_s "$duration_s" \
    --argjson extra "$extra" \
    '{
      run_id: $run_id,
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      manifest: $manifest,
      status: $status,
      duration_s: $duration_s
    } + $extra'
}

emit_chain_event() {
  local event="$1" task="$2" run_id="$3" chain_run_id="$4" issue_run_id="$5" status="$6" duration_s="${7:-null}" extra="${8:-}"
  [ -n "$extra" ] || extra='{}'
  local data
  data=$(event_data "$event" "$run_id" "$chain_run_id" "$issue_run_id" "$status" "$duration_s" "$extra")
  emit_event_keyed studio chain "$event" "$task" "$data" \
    --instance-id "$run_id" \
    --idem-key "studio-chain:$run_id:$event:${chain_run_id:-none}:${issue_run_id:-none}:$task" \
    >/dev/null 2>&1 || true
  printf '{"event":"%s","task":"%s","data":%s}\n' "$event" "$task" "$data" >> "$EVENTS_JSONL"
}

write_run_state() {
  local status="$1" failure_reason="${2:-}"
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest "$MANIFEST" \
    --arg status "$status" \
    --arg started_at "$RUN_STARTED_TS" \
    --arg report "$RUN_REPORT" \
    --arg failure_reason "$failure_reason" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest: $manifest,
      status: $status,
      started_at: $started_at,
      report: $report,
      failure_reason: (if $failure_reason == "" then null else $failure_reason end)
    }' > "$RUN_STATE_JSON"
}

generated_file_count_between() {
  local worktree="$1" before="$2" after="$3"
  git -C "$worktree" diff --name-only "$before" "$after" 2>/dev/null \
    | awk '
      /(^|\/)(docs-surface[.]json|.*manifest.*[.](json|ya?ml))$/ { count += 1; next }
      /(^|\/)chanakya\/snapshots\// { count += 1; next }
      /(^|\/)_shared\/schemas\/capability-manifest[.]json$/ { count += 1; next }
      END { print count + 0 }
    '
}

diff_stats_json() {
  local worktree="$1" before="$2" after="$3"
  local stats
  stats=$(git -C "$worktree" diff --numstat "$before" "$after" 2>/dev/null \
    | awk '
      BEGIN { files=0; add=0; del=0 }
      { files += 1; if ($1 ~ /^[0-9]+$/) add += $1; if ($2 ~ /^[0-9]+$/) del += $2 }
      END { printf "{\"files_changed\":%d,\"additions\":%d,\"deletions\":%d}", files, add, del }
    ')
  jq -cn --argjson stats "$stats" --argjson generated "$(generated_file_count_between "$worktree" "$before" "$after")" \
    '$stats + {generated_file_count: $generated}'
}

ingest_worker_summary() {
  local chain_name="$1" issue="$2" host="$3" worktree="$4" before="$5" after="$6" exit_code="$7" started_at="$8" chain_run_id="$9" issue_run_id="${10}"
  local summary_path="$worktree/.studio/chain-worker-summary.json"
  local dest="$SUMMARY_ROOT/${chain_name}-issue-${issue}-${issue_run_id}.json"
  local ended_at duration_s stats
  ended_at=$(now_epoch)
  duration_s=$(duration_since "$started_at" "$ended_at")
  stats=$(diff_stats_json "$worktree" "$before" "$after")

  if [ -f "$summary_path" ] && jq -e . "$summary_path" >/dev/null 2>&1; then
    jq -c \
      --arg run_id "$RUN_ID" \
      --arg chain_run_id "$chain_run_id" \
      --arg issue_run_id "$issue_run_id" \
      --arg host "$host" \
      --argjson exit_code "$exit_code" \
      --arg before "$before" \
      --arg after "$after" \
      --argjson duration_s "$duration_s" \
      --argjson stats "$stats" \
      '. + {
        schema_version: (.schema_version // 1),
        run_id: (.run_id // $run_id),
        chain_run_id: (.chain_run_id // $chain_run_id),
        issue_run_id: (.issue_run_id // $issue_run_id),
        host: (.host // $host),
        exit_code: (.exit_code // $exit_code),
        duration_s: (.duration_s // $duration_s),
        commit_before: (.commit_before // $before),
        commit_after: (.commit_after // $after),
        files_changed: (.files_changed // $stats.files_changed),
        additions: (.additions // $stats.additions),
        deletions: (.deletions // $stats.deletions),
        generated_file_count: (.generated_file_count // $stats.generated_file_count),
        telemetry_gaps: (.telemetry_gaps // [])
      }' "$summary_path" > "$dest"
  else
    jq -n \
      --arg run_id "$RUN_ID" \
      --arg chain_run_id "$chain_run_id" \
      --arg issue_run_id "$issue_run_id" \
      --arg chain "$chain_name" \
      --argjson issue "$issue" \
      --arg host "$host" \
      --argjson exit_code "$exit_code" \
      --arg before "$before" \
      --arg after "$after" \
      --argjson duration_s "$duration_s" \
      --argjson stats "$stats" \
      '{
        schema_version: 1,
        run_id: $run_id,
        chain_run_id: $chain_run_id,
        issue_run_id: $issue_run_id,
        chain: $chain,
        issue_number: $issue,
        host: $host,
        exit_code: $exit_code,
        duration_s: $duration_s,
        commit_before: $before,
        commit_after: $after,
        files_changed: $stats.files_changed,
        additions: $stats.additions,
        deletions: $stats.deletions,
        generated_file_count: $stats.generated_file_count,
        tests: [],
        lints: [],
        builds: [],
        tokens: null,
        model: null,
        model_recommendation: null,
        telemetry_gaps: ["worker_summary_missing", "model", "tokens", "tests_lints_builds"]
      }' > "$dest"
  fi

  printf '%s\n' "$dest"
}

worker_summary_tracked() {
  local worktree="$1"
  git -C "$worktree" ls-tree -r --name-only HEAD -- .studio/chain-worker-summary.json 2>/dev/null | grep -q .
}

generate_run_report() {
  local status="$1" failure_reason="${2:-}" ended_ts ended_epoch duration_s summary_count
  ended_ts=$(iso_ts_now)
  ended_epoch=$(now_epoch)
  duration_s=$(duration_since "$RUN_STARTED_AT" "$ended_epoch")
  summary_count=$(find "$SUMMARY_ROOT" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')

  {
    printf '# Studio Chain Run Report\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Manifest: `%s`\n' "$MANIFEST"
    printf -- '- Status: `%s`\n' "$status"
    printf -- '- Started: `%s`\n' "$RUN_STARTED_TS"
    printf -- '- Ended: `%s`\n' "$ended_ts"
    printf -- '- Duration: `%ss`\n' "$duration_s"
    [ -n "$failure_reason" ] && printf -- '- Failure reason: `%s`\n' "$failure_reason"
    printf '\n## Chains And Issues\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        ["| Chain | Issue | Host | Exit | Duration | Files | LOC | Generated | Model | Token Data | Gaps |",
         "|---|---:|---|---:|---:|---:|---:|---:|---|---|---|"],
        (.[] | "| \(.chain // "unknown") | #\(.issue_number // "unknown") | \(.host // "unknown") | \(.exit_code // "unknown") | \(.duration_s // "unknown")s | \(.files_changed // 0) | +\(.additions // 0)/-\(.deletions // 0) | \(.generated_file_count // 0) | \(.model // .model_name // "missing") | \(if (.tokens // null) == null then "missing" else "present" end) | \((.telemetry_gaps // []) | join(", ")) |")
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No worker summaries were ingested.\n'
    fi
    printf '\n## PRs And Review\n\n'
    if [ -n "$FINAL_PR_URL" ]; then
      printf -- '- PR URL: %s\n' "$FINAL_PR_URL"
    else
      printf -- '- PR URL: not opened\n'
    fi
    printf '\n## Telemetry Gaps\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        [.[].telemetry_gaps[]?] | group_by(.) | map({gap: .[0], count: length}) | sort_by(-.count) |
        if length == 0 then "No worker-declared gaps."
        else .[] | "- \(.gap): \(.count)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf -- '- worker_summary_missing: all issues\n'
    fi
    printf '\n## Improvement Candidates\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def gap_count($g): [.[].telemetry_gaps[]? | select(. == $g)] | length;
        [
          (if gap_count("worker_summary_missing") > 0 then "- Require worker hosts to write `.studio/chain-worker-summary.json` before exit." else empty end),
          (if gap_count("tokens") > 0 or gap_count("token_usage") > 0 then "- Add host-specific token extraction to worker summaries." else empty end),
          (if gap_count("tests_lints_builds") > 0 then "- Standardize test/lint/build outcome capture in worker summaries." else empty end)
        ] | if length == 0 then "No threshold-based candidates from this run." else .[] end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf -- '- Add worker summary enforcement before relying on chain metrics.\n'
    fi
    printf '\n## Privacy\n\n'
    printf 'This report is private local telemetry under `~/.dev-studio/generic-dev-studio/chain-runs/`. Public PR and issue comments should include run IDs, PR URLs, issue numbers, and abstract gap names only, not private project file paths or velocity details.\n'
  } > "$RUN_REPORT"
}

finish_run() {
  local status="${1:-$RUN_STATUS}" reason="${2:-$RUN_FAILURE_REASON}" duration_s
  RUN_FINISHED=1
  RUN_STATUS="$status"
  RUN_FAILURE_REASON="$reason"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run complete; no chain-run report written"
    return 0
  fi
  write_run_state "$status" "$reason"
  generate_run_report "$status" "$reason"
  duration_s=$(duration_since "$RUN_STARTED_AT")
  emit_chain_event chain_run_completed "" "$RUN_ID" "" "" "$status" "$duration_s" \
    "$(jq -cn --arg report "$RUN_REPORT" --arg reason "$reason" '{report:$report, failure_reason:(if $reason == "" then null else $reason end)}')"
  log "report written to $RUN_REPORT"
}

abort_run() {
  local reason="${1:-failed}"
  finish_run failed "$reason"
  exit 1
}

finish_unexpected_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${RUN_FINISHED:-0}" != "1" ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
    finish_run failed "unexpected_exit_$rc"
  fi
}

slugify() {
  printf '%s' "$1" | tr '/[:space:]' '--' | tr -cd '[:alnum:]_.-'
}

resolve_manifest() {
  local input="$1" candidate
  if [ -f "$input" ]; then
    printf '%s\n' "$input"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yaml"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yml"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf 'studio-chain-runner: manifest not found: %s\n' "$input" >&2
  printf 'studio-chain-runner: tried %s and %s\n' "$REPO_ROOT/chains/$input.yaml" "$REPO_ROOT/chains/$input.yml" >&2
  exit 2
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

host_launch_home() {
  resolve_user_login_home 2>/dev/null || true
}

host_preflight() {
  local host="$1" repo="$2" launch_home
  launch_home=$(host_launch_home)
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
      printf 'DRY-RUN HOME=%q scripts/host-preflight.sh %q %q\n' "$launch_home" "$host" "$repo"
    else
      printf 'DRY-RUN scripts/host-preflight.sh %q %q\n' "$host" "$repo"
    fi
    return 0
  fi
  if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
    HOME="$launch_home" "$SCRIPT_DIR/host-preflight.sh" "$host" "$repo"
  else
    "$SCRIPT_DIR/host-preflight.sh" "$host" "$repo"
  fi
}

available_ram_gib() {
  if [ -n "${STUDIO_CHAIN_AVAILABLE_RAM_GIB:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_AVAILABLE_RAM_GIB"
    return 0
  fi

  if command -v vm_stat >/dev/null 2>&1; then
    vm_stat 2>/dev/null | awk '
      /page size of/ { gsub(/\./, "", $8); page=$8 }
      /Pages free:/ { gsub(/\./, "", $3); free=$3 }
      /Pages inactive:/ { gsub(/\./, "", $3); inactive=$3 }
      /Pages speculative:/ { gsub(/\./, "", $3); speculative=$3 }
      END {
        if (page <= 0) page = 4096
        gib = ((free + inactive + speculative) * page) / 1073741824
        if (gib < 0) gib = 0
        printf "%d\n", gib
      }'
    return 0
  fi

  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ { printf "%d\n", ($2 * 1024) / 1073741824; found=1 } END { if (!found) print 0 }' /proc/meminfo
    return 0
  fi

  printf '4\n'
}

healthy_xcodebuild_offload_count() {
  local registry ids id row status health_cmd count=0
  registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf '0\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0\n'; return 0; }
  health_cmd="${STUDIO_CHAIN_NODE_HEALTH_CMD:-$SCRIPT_DIR/node-health.sh}"

  ids=$(jq -r '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index("xcodebuild")) | .id' "$registry" 2>/dev/null) || ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    node_is_self "$id" && continue
    row=$("$health_cmd" "$id" 2>/dev/null | head -n 1)
    status=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    case "$status" in
      healthy|moved) count=$((count + 1)) ;;
    esac
  done <<EOF
$ids
EOF
  printf '%s\n' "$count"
}

chain_worker_pool_size() {
  if [ -n "${STUDIO_CHAIN_WORKER_POOL:-}" ]; then
    case "$STUDIO_CHAIN_WORKER_POOL" in
      ''|*[!0-9]*|0) printf 'studio-chain-runner: invalid STUDIO_CHAIN_WORKER_POOL=%s\n' "$STUDIO_CHAIN_WORKER_POOL" >&2; exit 2 ;;
      *) printf '%s\n' "$STUDIO_CHAIN_WORKER_POOL"; return 0 ;;
    esac
  fi

  local offload_count desired ram_gib per_worker_gib ram_cap max_workers
  offload_count=$(healthy_xcodebuild_offload_count)
  desired=$((offload_count + 1))

  ram_gib=$(available_ram_gib)
  case "$ram_gib" in ''|*[!0-9]*) ram_gib=0 ;; esac
  per_worker_gib="${STUDIO_CHAIN_WORKER_RAM_GIB:-6}"
  case "$per_worker_gib" in ''|*[!0-9]*|0) per_worker_gib=6 ;; esac
  ram_cap=$((ram_gib / per_worker_gib))
  [ "$ram_cap" -lt 1 ] && ram_cap=1

  max_workers="${STUDIO_CHAIN_MAX_WORKERS:-}"
  if [ -n "$max_workers" ]; then
    case "$max_workers" in ''|*[!0-9]*|0) max_workers=1 ;; esac
    [ "$desired" -gt "$max_workers" ] && desired="$max_workers"
  fi
  [ "$desired" -gt "$ram_cap" ] && desired="$ram_cap"
  [ "$desired" -lt 1 ] && desired=1
  printf '%s\n' "$desired"
}

MANIFEST=$(resolve_manifest "$MANIFEST")
if [ "$DRY_RUN" -eq 0 ]; then
  write_run_state running ""
fi
emit_chain_event chain_run_started "" "$RUN_ID" "" "" running 0 \
  "$(jq -cn --arg manifest_arg "$MANIFEST" --arg only_chain "$ONLY_CHAIN" --arg host_override "$HOST_OVERRIDE" '{manifest_arg:$manifest_arg, only_chain:(if $only_chain == "" then null else $only_chain end), host_override:(if $host_override == "" then null else $host_override end)}')"
trap finish_unexpected_exit EXIT

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
  local chain_name="$1" chain_branch="$2" issue="$3" host="$4" worktree="$5" chain_run_id="$6" issue_run_id="$7" before="$8"
  local issue_json issue_title issue_body spawn prompt summary_path
  local -a spawn_argv
  local launch_home=""

  issue_json=$(gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,body,url,state)
  issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
  issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  summary_path="$worktree/.studio/chain-worker-summary.json"

  spawn=$(host_spawn_command "$host")
  # shellcheck disable=SC2206
  spawn_argv=( $spawn )
  launch_home=$(host_launch_home)

  prompt=$(cat <<EOF
Implement this studio issue in a fresh chain-runner session.

You are executing one issue inside an automated chain runner.

Repo: $REPO_SLUG
Run UUID: $RUN_ID
Chain-run UUID: $chain_run_id
Issue-run UUID: $issue_run_id
Chain: $chain_name
Chain branch: $chain_branch
Issue: #$issue - $issue_title
Working directory: $worktree
Required summary artifact: $summary_path

Rules:
- Work only in this working directory.
- Implement only issue #$issue.
- Keep changes scoped to this issue.
- Commit the result on the current branch.
- Include "Closes #$issue" in the commit message.
- Before exit, write $summary_path as valid JSON.
- Do not add or commit $summary_path; it is a private parent-runner artifact.
- Do not open a PR.
- Do not merge to main.
- Do not close the issue; the chain runner owns issue closure after integration.
- If blocked, exit non-zero after writing a concise reason.

Summary JSON fields:
- schema_version: 1
- run_id: "$RUN_ID"
- chain_run_id: "$chain_run_id"
- issue_run_id: "$issue_run_id"
- chain: "$chain_name"
- issue_number: $issue
- issue_title: "$issue_title"
- host: "$host"
- model/model_version/effort when known, otherwise null
- started_at/ended_at/duration_s
- exit_code
- commit_before: "$before"
- commit_after
- files_changed/additions/deletions/generated_file_count
- tests/lints/builds arrays with command/outcome when run
- tokens object when available, otherwise null
- telemetry_gaps array listing missing fields such as "tokens" or "model"
- blocked_reason when nonzero

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

  if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
    (cd "$worktree" && env HOME="$launch_home" "${spawn_argv[@]}" "$prompt")
  else
    (cd "$worktree" && "${spawn_argv[@]}" "$prompt")
  fi
}

finalize_chain_pr() {
  local chain_name="$1" chain_branch="$2" chain_worktree="$3" base="$4" chain_run_id="$5"
  local pr_url pr_number review_started_at review_rc review_duration

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

Chain run: \`$RUN_ID\`
Chain-run UUID: \`$chain_run_id\`
Private report: local only; resolve by run ID on the machine that ran the chain.

Review gate: \`scripts/pr-headless-review.sh <pr> --method auto\`.")
  pr_number=$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  FINAL_PR_URL="$pr_url"
  log "opened PR $pr_url"
  emit_chain_event chain_pr_opened "$pr_number" "$RUN_ID" "$chain_run_id" "" completed 0 \
    "$(jq -cn --arg pr_url "$pr_url" --arg pr_number "$pr_number" --arg branch "$chain_branch" '{pr_url:$pr_url, pr_number:$pr_number, branch:$branch}')"
  if ! gh pr comment "$pr_number" --repo "$REPO_SLUG" --body "Chain run: \`$RUN_ID\`

Private telemetry report: local only; resolve by run ID on the machine that ran the chain.

Public-safe telemetry: run/chain UUIDs and abstract gap names only."; then
    abort_run "PR telemetry comment failed for $pr_url"
  fi

  review_started_at=$(now_epoch)
  set +e
  "$SCRIPT_DIR/pr-headless-review.sh" "$pr_number" --method auto
  review_rc=$?
  set -e
  review_duration=$(duration_since "$review_started_at")
  if [ "$review_rc" -eq 0 ]; then
    emit_chain_event chain_review_completed "$pr_number" "$RUN_ID" "$chain_run_id" "" completed "$review_duration" \
      "$(jq -cn --arg pr_url "$pr_url" --argjson exit_code "$review_rc" '{pr_url:$pr_url, exit_code:$exit_code}')"
  else
    emit_chain_event chain_review_completed "$pr_number" "$RUN_ID" "$chain_run_id" "" failed "$review_duration" \
      "$(jq -cn --arg pr_url "$pr_url" --argjson exit_code "$review_rc" '{pr_url:$pr_url, exit_code:$exit_code}')"
    abort_run "PR review failed for $pr_url"
  fi
}

run_issue_job() {
  local name="$1" branch="$2" issue="$3" host="$4" issue_worktree="$5" issue_branch="$6" chain_run_id="$7" issue_run_id="$8" result_file="$9"
  local before after worker_rc summary_file issue_duration summary_payload issue_started_at
  issue_started_at=$(now_epoch)

  log "issue #$issue -> $issue_branch"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$REPO_ROOT" worktree remove --force "$issue_worktree" 2>/dev/null || rm -rf "$issue_worktree"
    git -C "$REPO_ROOT" worktree add -B "$issue_branch" "$issue_worktree" "$branch"
    before=$(git -C "$issue_worktree" rev-parse HEAD)
  else
    printf 'DRY-RUN git worktree add -B %q %q %q\n' "$issue_branch" "$issue_worktree" "$branch"
    before="dry-run-before"
  fi

  emit_chain_event chain_issue_started "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" running 0 \
    "$(jq -cn --arg chain "$name" --arg branch "$issue_branch" --arg host "$host" --arg before "$before" '{chain:$chain, issue_branch:$branch, host:$host, commit_before:$before}')"

  set +e
  execute_issue_session "$name" "$branch" "$issue" "$host" "$issue_worktree" "$chain_run_id" "$issue_run_id" "$before"
  worker_rc=$?
  set -e

  if [ "$DRY_RUN" -eq 1 ]; then
    jq -n \
      --arg issue "$issue" \
      --arg branch "$issue_branch" \
      --arg worktree "$issue_worktree" \
      '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree}' > "$result_file"
    return 0
  fi

  after=$(git -C "$issue_worktree" rev-parse HEAD)
  summary_file=$(ingest_worker_summary "$name" "$issue" "$host" "$issue_worktree" "$before" "$after" "$worker_rc" "$issue_started_at" "$chain_run_id" "$issue_run_id")
  issue_duration=$(duration_since "$issue_started_at")
  summary_payload=$(jq -c --arg summary "$summary_file" --arg after "$after" --argjson exit_code "$worker_rc" --argjson duration_s "$issue_duration" \
    '{summary:$summary, commit_after:$after, exit_code:$exit_code, worker_duration_s:$duration_s, telemetry_gaps:(.telemetry_gaps // [])}' "$summary_file")

  if worker_summary_tracked "$issue_worktree"; then
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" \
      "$(jq -cn --arg summary "$summary_file" --arg reason "worker_summary_committed" '{summary:$summary, failure_reason:$reason}')"
    jq -n --arg issue "$issue" --arg reason "issue #$issue committed private worker summary" \
      '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
    return 0
  fi

  rm -rf "$issue_worktree/.studio"
  if [ "$worker_rc" -ne 0 ]; then
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" "$summary_payload"
    jq -n --arg issue "$issue" --argjson rc "$worker_rc" --arg reason "issue #$issue worker exited $worker_rc" \
      '{status:"failed", issue:($issue|tonumber), exit_code:$rc, reason:$reason}' > "$result_file"
    return 0
  fi

  if [ "$after" = "$before" ]; then
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" \
      "$(jq -cn --arg summary "$summary_file" --arg reason "no_commit" '{summary:$summary, failure_reason:$reason}')"
    printf 'studio-chain-runner: issue #%s produced no commit; leaving worktree at %s\n' "$issue" "$issue_worktree" >&2
    jq -n --arg issue "$issue" --arg reason "issue #$issue produced no commit" \
      '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
    return 0
  fi

  emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed "$issue_duration" "$summary_payload"
  jq -n \
    --arg issue "$issue" \
    --arg branch "$issue_branch" \
    --arg worktree "$issue_worktree" \
    --arg before "$before" \
    --arg after "$after" \
    '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree, commit_before:$before, commit_after:$after}' > "$result_file"
}

wait_for_issue_slot() {
  local blocking="${1:-0}" running pid
  local -a next_pids
  while :; do
    running=0
    next_pids=()
    for pid in "${ISSUE_PIDS[@]:-}"; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        next_pids+=("$pid")
        running=$((running + 1))
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    if [ "${#next_pids[@]}" -gt 0 ]; then
      ISSUE_PIDS=("${next_pids[@]}")
    else
      ISSUE_PIDS=()
    fi
    [ "$running" -lt "$CHAIN_WORKER_POOL" ] && return 0
    [ "$blocking" = "1" ] || return 0
    sleep 2
  done
}

wait_for_all_issue_jobs() {
  local pid
  for pid in "${ISSUE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
  ISSUE_PIDS=()
}

for ((idx = 0; idx < chain_count; idx++)); do
  name=$(yq -r ".chains[$idx].name" "$MANIFEST")
  base=$(yq -r ".chains[$idx].base // \"main\"" "$MANIFEST")
  branch=$(yq -r ".chains[$idx].branch // (\"feature/\" + .chains[$idx].name)" "$MANIFEST")
  host=$(yq -r ".chains[$idx].host // \"auto\"" "$MANIFEST")
  issue_count=$(yq -r ".chains[$idx].issues | length" "$MANIFEST")
  chain_run_id=$(mint_uuidv7)
  chain_started_at=$(now_epoch)

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
  chain_results_dir="$RUN_ROOT/$chain_slug-results-$chain_run_id"
  CHAIN_WORKER_POOL=$(chain_worker_pool_size)

  log "starting chain $name on $branch from latest $base using host=$host worker_pool=$CHAIN_WORKER_POOL"
  emit_chain_event chain_started "" "$RUN_ID" "$chain_run_id" "" running 0 \
    "$(jq -cn --arg name "$name" --arg branch "$branch" --arg base "$base" --arg host "$host" --argjson issue_count "$issue_count" --argjson worker_pool "$CHAIN_WORKER_POOL" '{chain:$name, branch:$branch, base:$base, host:$host, issue_count:$issue_count, worker_pool:$worker_pool}')"
  host_preflight "$host" "$REPO_ROOT" || abort_run "host preflight failed for $host"
  run git -C "$REPO_ROOT" fetch origin --prune
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$chain_results_dir"
    if [ ! -d "$chain_worktree/.git" ]; then
      git -C "$REPO_ROOT" worktree add -B "$branch" "$chain_worktree" "origin/$base"
    fi
    git -C "$chain_worktree" checkout "$branch"
    git -C "$chain_worktree" reset --hard "origin/$base"
  else
    mkdir -p "$chain_results_dir"
    printf 'DRY-RUN git worktree add -B %q %q origin/%q\n' "$branch" "$chain_worktree" "$base"
  fi

  ISSUE_PIDS=()
  for ((i = 0; i < issue_count; i++)); do
    issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
    issue_slug=$(slugify "$issue")
    issue_branch="$branch-issue-$issue_slug"
    issue_worktree="$RUN_ROOT/$chain_slug-issue-$issue_slug"
    issue_run_id=$(mint_uuidv7)
    result_file="$chain_results_dir/issue-$issue-$issue_run_id.json"

    if [ "$DRY_RUN" -eq 1 ]; then
      run_issue_job "$name" "$branch" "$issue" "$host" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$result_file"
    else
      wait_for_issue_slot 1
      run_issue_job "$name" "$branch" "$issue" "$host" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$result_file" &
      ISSUE_PIDS+=("$!")
    fi
  done

  wait_for_all_issue_jobs

  for ((i = 0; i < issue_count; i++)); do
    issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
    result_file=$(find "$chain_results_dir" -maxdepth 1 -name "issue-$issue-*.json" -print -quit 2>/dev/null || true)
    if [ -z "$result_file" ] || [ ! -r "$result_file" ]; then
      abort_run "issue #$issue produced no runner result"
    fi
    result_status=$(jq -r '.status // "failed"' "$result_file")
    if [ "$result_status" != "completed" ]; then
      result_reason=$(jq -r '.reason // "issue failed"' "$result_file")
      abort_run "$result_reason"
    fi
    issue_branch=$(jq -r '.issue_branch' "$result_file")
    issue_worktree=$(jq -r '.issue_worktree' "$result_file")
    if [ "$DRY_RUN" -eq 0 ]; then
      git -C "$chain_worktree" checkout "$branch"
      git -C "$issue_worktree" rebase "$branch"
      git -C "$chain_worktree" merge --ff-only "$issue_branch"
      git -C "$REPO_ROOT" worktree remove "$issue_worktree"
      git -C "$REPO_ROOT" branch -D "$issue_branch"
    else
      printf 'DRY-RUN git -C %q checkout %q\n' "$chain_worktree" "$branch"
      printf 'DRY-RUN git -C %q rebase %q\n' "$issue_worktree" "$branch"
      printf 'DRY-RUN git -C %q merge --ff-only %q\n' "$chain_worktree" "$issue_branch"
      printf 'DRY-RUN git -C %q worktree remove %q\n' "$REPO_ROOT" "$issue_worktree"
      printf 'DRY-RUN git -C %q branch -D %q\n' "$REPO_ROOT" "$issue_branch"
    fi
  done

  finalize_chain_pr "$name" "$branch" "$chain_worktree" "$base" "$chain_run_id"
  chain_duration=$(duration_since "$chain_started_at")
  emit_chain_event chain_completed "" "$RUN_ID" "$chain_run_id" "" completed "$chain_duration" \
    "$(jq -cn --arg name "$name" --arg pr_url "$FINAL_PR_URL" '{chain:$name, pr_url:(if $pr_url == "" then null else $pr_url end)}')"

  for ((i = 0; i < issue_count; i++)); do
    issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
    if [ "$DRY_RUN" -eq 0 ]; then
      gh issue close "$issue" --repo "$REPO_SLUG" --comment "Merged through chain PR: ${FINAL_PR_URL:-$branch}

Chain run: $RUN_ID" \
        || gh issue comment "$issue" --repo "$REPO_SLUG" --body "Merged through chain PR: ${FINAL_PR_URL:-$branch}

Chain run: $RUN_ID"
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

finish_run completed ""
log "all requested chains processed"
