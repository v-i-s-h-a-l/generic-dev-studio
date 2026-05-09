#!/usr/bin/env bash
# Event-derived chain-run state projection helpers.

# No `set -e` here. This file is sourced by runner, monitor, and fixtures.

chain_run_state_events_path_for_state() {
  local state_path="${1:?usage: chain_run_state_events_path_for_state <state.json>}"
  printf '%s/events.jsonl\n' "$(dirname "$state_path")"
}

chain_run_state_projection_json() {
  local state_path="${1:?usage: chain_run_state_projection_json <state.json> [events.jsonl]}"
  local events_path="${2:-}"
  [ -n "$events_path" ] || events_path=$(chain_run_state_events_path_for_state "$state_path")
  [ -f "$state_path" ] || return 1
  if [ ! -s "$events_path" ]; then
    jq -c '.' "$state_path"
    return
  fi

  jq -c --slurpfile events "$events_path" '
    def event_chain_id($e): (($e.chain_run_id // $e.data.chain_run_id // "") | tostring);
    def event_issue_id($e): (($e.issue_run_id // $e.data.issue_run_id // "") | tostring);
    def event_issue_number($e): (($e.task // $e.data.issue_number // $e.data.issue // "") | tostring);
    def event_at($e): ($e.created_at // $e.data.created_at // .updated_at // "");
    def issue_lifecycle_rank($state):
      if $state == "closed" then 5
      elif $state == "merged" then 4
      elif $state == "smoke-passed" then 3
      elif $state == "implemented-local" or $state == "failed" then 2
      elif $state == "implementation-running" then 1
      else 0
      end;
    def append_lifecycle($state; $at; $reason):
      .lifecycle_state = $state
      | .lifecycle_history = (
          (.lifecycle_history // []) as $history
          | if (($history | length) > 0 and ($history[-1].state // "") == $state) then $history
            else $history + [{state:$state, at:$at, reason:$reason}]
            end
        );
    def clear_current_failure:
      del(.failure_reason) | del(.exit_code);
    def completion_exception_for($chain_id; $issue):
      [ $events[]
        | select(((.event // "") | tostring) as $event_name | ["chain_issue_completion_exception", "chain_issue_finalization_exception"] | index($event_name))
        | select((event_chain_id(.) == "" or event_chain_id(.) == $chain_id))
        | select(
            (event_issue_id(.) != "" and event_issue_id(.) == (($issue.issue_run_id // "") | tostring))
            or (event_issue_number(.) != "" and event_issue_number(.) == (($issue.number // $issue.issue // "") | tostring))
          )
      ] | length > 0;
    def update_issue_from_event($e; $status; $lifecycle; $reason; $integrated; $closed):
      (event_chain_id($e)) as $cid
      | (event_issue_id($e)) as $iid
      | (event_issue_number($e)) as $inum
      | (event_at($e)) as $at
      | ($e.data // {}) as $data
      | (.chains[]? | select($cid == "" or ((.chain_run_id // "") | tostring) == $cid) | .issues[]? | select(
          ($iid != "" and ((.issue_run_id // "") | tostring) == $iid)
          or ($iid == "" and $inum != "" and ((.number // .issue // "") | tostring) == $inum)
        )) |= (
          if issue_lifecycle_rank($lifecycle) < issue_lifecycle_rank((.lifecycle_state // "")) then .
          else
            .status = $status
            | append_lifecycle($lifecycle; $at; $reason)
            | if $integrated then .integrated = true else . end
            | if $closed then .closed = true | .closed_at = $at else . end
            | if (($data.commit_before // "") | tostring) != "" then .commit_before = $data.commit_before else . end
            | if (($data.commit_after // "") | tostring) != "" then .commit_after = $data.commit_after else . end
            | if (($data.summary // "") | tostring) != "" then .summary = $data.summary else . end
            | if $status == "failed" then
                .failure_reason = (($data.failure_reason // $reason // "failed") | tostring)
                | if ($data.exit_code // null) != null then .exit_code = $data.exit_code else . end
              else
                clear_current_failure
              end
            end
        );
    def update_chain_from_event($e; $status; $reason):
      (event_chain_id($e)) as $cid
      | (event_at($e)) as $at
      | ($e.data // {}) as $data
      | (.chains[]? | select($cid != "" and ((.chain_run_id // "") | tostring) == $cid)) |= (
          if ((.status // "") == "completed" and $status != "completed") then .
          else
            .status = $status
            | if (($data.pr_url // "") | tostring) != "" then .pr_url = $data.pr_url else . end
            | if $status == "completed" then
                .completed_at = $at | del(.failure_reason)
              elif $status == "failed" then
                .failure_reason = (($data.failure_reason // $reason // "failed") | tostring)
              else . end
            end
        );
    def complete_issue_from_chain($cid; $at; $data):
      if completion_exception_for($cid; .) then .
      else
        .status = "completed"
        | .integrated = true
        | if issue_lifecycle_rank("merged") < issue_lifecycle_rank((.lifecycle_state // "")) then .
          else append_lifecycle("merged"; $at; "chain-pr-finalized")
          end
        | if (($data.commit_after // "") | tostring) != "" then .commit_after = $data.commit_after else . end
        | .provenance.merge = ((.provenance.merge // {}) + {
            finalized_at:$at,
            chain_pr_commit_after:(if (($data.commit_after // "") | tostring) == "" then null else $data.commit_after end)
          })
        | clear_current_failure
      end;
    def complete_chain_from_event($e):
      (event_chain_id($e)) as $cid
      | (event_at($e)) as $at
      | ($e.data // {}) as $data
      | update_chain_from_event($e; "completed"; "chain-completed")
      | (.chains[]? | select($cid != "" and ((.chain_run_id // "") | tostring) == $cid) | .issues[]?) |= (
          complete_issue_from_chain($cid; $at; $data)
        );
    def apply_event($e):
      (($e.event // "") | tostring) as $name
      | (($e.status // $e.data.status // "") | tostring) as $status
      | if $name == "chain_started" then update_chain_from_event($e; "running"; "chain-started")
        elif $name == "chain_pr_opened" then update_chain_from_event($e; "running"; "chain-pr-opened")
        elif $name == "chain_review_completed" and $status == "failed" then update_chain_from_event($e; "failed"; "chain-review-failed")
        elif $name == "chain_completed" then complete_chain_from_event($e)
        elif $name == "chain_run_completed" then
          if ((.status // "") == "completed" and $status != "completed") then .
          else .status = $status | if $status == "completed" then del(.failure_reason) else . end
          end
        elif $name == "chain_issue_started" then update_issue_from_event($e; "running"; "implementation-running"; "chain_issue_started"; false; false)
        elif $name == "chain_parent_commit_finalized" then update_issue_from_event($e; "running"; "implemented-local"; "parent-finalized"; false; false)
        elif $name == "chain_issue_completed" and $status == "completed" then update_issue_from_event($e; "completed"; "smoke-passed"; "chain_issue_completed"; false; false)
        elif $name == "chain_issue_completed" and $status == "failed" then update_issue_from_event($e; "failed"; "failed"; (($e.data.failure_reason // "chain_issue_completed_failed") | tostring); false; false)
        elif $name == "chain_issue_merged" then update_issue_from_event($e; "completed"; "merged"; "chain-branch-integration"; true; false)
        elif $name == "chain_issue_closed" then update_issue_from_event($e; "completed"; "closed"; "issue-closed"; true; true)
        else .
        end;
    . as $state
    | ($events | map(select((.run_id // .data.run_id // $state.run_id // "") == ($state.run_id // "")))) as $run_events
    | reduce $run_events[] as $event (.;
        apply_event($event)
      )
  ' "$state_path"
}

chain_run_state_projection_file() {
  local state_path="${1:?usage: chain_run_state_projection_file <state.json> <events.jsonl> <output-json>}"
  local events_path="${2:?usage: chain_run_state_projection_file <state.json> <events.jsonl> <output-json>}"
  local output_path="${3:?usage: chain_run_state_projection_file <state.json> <events.jsonl> <output-json>}"
  chain_run_state_projection_json "$state_path" "$events_path" > "$output_path"
}

chain_run_state_projection_fingerprint_json() {
  local input_path="${1:?usage: chain_run_state_projection_fingerprint_json <state-or-projection.json>}"
  jq -c '
    {
      run_id:(.run_id // null),
      status:(.status // null),
      failure_reason:(.failure_reason // null),
      halt_records:(.halt_records // []),
      decision_escrows:(.decision_escrows // []),
      chains:[(.chains // [])[]? | {
        chain_run_id:(.chain_run_id // null),
        name:(.name // null),
        status:(.status // null),
        pr_url:(.pr_url // null),
        failure_reason:(.failure_reason // null),
        completed_at:(.completed_at // null),
        issues:[(.issues // [])[]? | {
          number:(.number // .issue // null),
          issue_run_id:(.issue_run_id // null),
          status:(.status // null),
          integrated:(.integrated // false),
          closed:(.closed // false),
          lifecycle_state:(.lifecycle_state // null),
          failure_reason:(.failure_reason // null),
          exit_code:(.exit_code // null),
          commit_before:(.commit_before // null),
          commit_after:(.commit_after // null),
          summary:(.summary // null)
        }]
      }]
    }
  ' "$input_path"
}

chain_run_state_projection_mismatch_json() {
  local current_path="${1:?usage: chain_run_state_projection_mismatch_json <current-state.json> <projection.json>}"
  local projection_path="${2:?usage: chain_run_state_projection_mismatch_json <current-state.json> <projection.json>}"
  local current projection
  current=$(chain_run_state_projection_fingerprint_json "$current_path")
  projection=$(chain_run_state_projection_fingerprint_json "$projection_path")
  jq -cn --argjson current "$current" --argjson projection "$projection" '{
    status:(if $current == $projection then "ok" else "mismatch" end),
    current:$current,
    projection:$projection
  }'
}

chain_run_state_reconcile_file() {
  local state_path="${1:?usage: chain_run_state_reconcile_file <state.json> <events.jsonl> [reason] }"
  local events_path="${2:?usage: chain_run_state_reconcile_file <state.json> <events.jsonl> [reason] }"
  local reason="${3:-startup}"
  local projection tmp backup reconciled_at mismatch

  projection=$(mktemp -t chain-run-state-projection.XXXXXX)
  tmp=$(mktemp -t chain-run-state-reconcile.XXXXXX)
  if ! chain_run_state_projection_file "$state_path" "$events_path" "$projection"; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "projection_failed" --arg state "$state_path" --arg events "$events_path" '{status:$status,state:$state,events:$events}'
    return 1
  fi
  if [ ! -s "$projection" ] || ! jq empty "$projection" >/dev/null 2>&1; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "projection_invalid" --arg state "$state_path" --arg events "$events_path" '{status:$status,state:$state,events:$events}'
    return 1
  fi

  mismatch=$(chain_run_state_projection_mismatch_json "$state_path" "$projection")
  if [ "$(printf '%s\n' "$mismatch" | jq -r '.status')" = "ok" ]; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "ok" --arg state "$state_path" --arg events "$events_path" '{status:$status,state:$state,events:$events,repaired:false}'
    return 0
  fi

  reconciled_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  backup="$state_path.stale-$reconciled_at"
  if ! cp "$state_path" "$backup"; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "backup_failed" --arg state "$state_path" --arg events "$events_path" '{status:$status,state:$state,events:$events}'
    return 1
  fi
  if ! jq \
    --arg reconciled_at "$reconciled_at" \
    --arg events "$events_path" \
    --arg reason "$reason" \
    --arg backup "$backup" \
    '.updated_at = $reconciled_at
     | .projection = {
         schema_version:1,
         source:"events.jsonl",
         reconciled_at:$reconciled_at,
         reason:$reason,
         stale_state_backup:$backup,
         events:$events
       }' "$projection" > "$tmp"
  then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "repair_projection_metadata_failed" --arg state "$state_path" --arg events "$events_path" --arg backup "$backup" '{status:$status,state:$state,events:$events,backup:$backup}'
    return 1
  fi
  if [ ! -s "$tmp" ] || ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "repair_output_invalid" --arg state "$state_path" --arg events "$events_path" --arg backup "$backup" '{status:$status,state:$state,events:$events,backup:$backup}'
    return 1
  fi
  if ! mv "$tmp" "$state_path"; then
    rm -f "$projection" "$tmp"
    jq -cn --arg status "repair_write_failed" --arg state "$state_path" --arg events "$events_path" --arg backup "$backup" '{status:$status,state:$state,events:$events,backup:$backup}'
    return 1
  fi
  rm -f "$projection"
  jq -cn \
    --arg status "repaired" \
    --arg state "$state_path" \
    --arg events "$events_path" \
    --arg backup "$backup" \
    --argjson mismatch "$mismatch" \
    '{status:$status,state:$state,events:$events,repaired:true,backup:$backup,mismatch:$mismatch}'
}
