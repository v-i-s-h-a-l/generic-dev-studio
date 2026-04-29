#!/usr/bin/env bash
# sweep-ingest.sh <debrief|build-check|release> <source-path> [flags]
#
# Steps 0A/0B/0B2 of the inbox sweep, unified. Replaces three per-kind scripts
# (one for regular task debriefs, one for manual-build-check debriefs, one
# for release debriefs) with a single dispatcher keyed on kind.
#
# Flags (subcommand-specific):
#   debrief:
#     --argus-exempt            Caller has determined argus-skip is OK;
#                               skip emitting review_pending. Mode pack owns
#                               the exemption rule-list.
#
# Exit codes:
#   0  ingest ok (or idempotent no-op)
#   2  parse / resolution error
#   3  dual-write partial failure propagated from lib-ledger

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

SUBCMD="${1:-}"
SRC="${2:-}"
shift 2 2>/dev/null || true

case "$SUBCMD" in
  debrief|build-check|release) ;;
  "") printf 'usage: sweep-ingest.sh <debrief|build-check|release> <source-path> [flags]\n' >&2; exit 2 ;;
  *) printf 'unknown subcommand: %s\n' "$SUBCMD" >&2; exit 2 ;;
esac
[ -n "$SRC" ] && [ -f "$SRC" ] || { printf 'sweep-ingest.sh: missing source %s\n' "$SRC" >&2; exit 2; }

PROJECT=$(resolve_project 2>/dev/null) || { printf 'sweep-ingest.sh: no project resolved\n' >&2; exit 2; }
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
RELEASES_DIR=$(resolve_releases_dir_for "$PROJECT")

# Post-#245 A.4 the inbox is YAML-only; legacy markdown debriefs are archived
# under plans/.legacy-archive/ and sweep-enumerate-debriefs no longer surfaces
# them. We still assert the suffix here to fail loud if a stale caller passes
# a markdown source.
case "$SRC" in
  *.yaml) ;;
  *) printf 'sweep-ingest: refusing non-YAML source %s — legacy markdown debrief surface retired by #245 A.4\n' "$SRC" >&2; exit 2 ;;
esac

# Atomically bump `accumulated_count` on an active waive file for the given
# gate. No-op if the file is absent (normal unwaived state). yq-based read +
# tmp+mv write preserves the read-mutate-atomic-write invariant used across
# lib-ledger. Failures are swallowed by the caller — accumulator drift is
# strictly less important than the caller's main emission.
bump_waive_counter() {
  local gate="${1:?bump_waive_counter <gate>}"
  local f
  f=$(resolve_waive_file "$gate" 2>/dev/null) || return 1
  [ -f "$f" ] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  local current new ts tmp
  current=$(yq -r '.accumulated_count // 0' "$f" 2>/dev/null || echo 0)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  new=$((current + 1))
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="$f.tmp.$$"
  yq ".accumulated_count = $new | .updated_at = \"$ts\"" "$f" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" \
    || { rm -f "$tmp"; return 1; }
}

# Resolve a task UUID from a legacy task id by scanning plans/tasks/*.yaml.
# Same pattern as `argus-emit-verdict.sh`; cheap enough per-sweep without an
# index lookup.
resolve_task_uuid_by_legacy_id() {
  local legacy_id="$1"
  [ -n "$legacy_id" ] || return 1
  [ -d "$TASKS_DIR" ] || return 1
  grep -lE "^legacy_task_id: *\"?${legacy_id}\"?$" "$TASKS_DIR"/*.yaml 2>/dev/null \
    | head -1 \
    | xargs -I{} basename {} .yaml 2>/dev/null
}

event_idem_seen() {
  local idem="${1:?event_idem_seen <idempotency-key>}"
  local events_dir
  events_dir=$(resolve_events_dir_for "$PROJECT" 2>/dev/null) || return 1
  [ -d "$events_dir" ] || return 1
  grep -F "\"idempotency_key\":\"$idem\"" "$events_dir"/*.jsonl >/dev/null 2>&1
}

emit_reconcile_event() {
  local event="${1:?emit_reconcile_event <event> <task> <data> <subject> <content>}"
  local task="${2:-}"
  local data="${3:-{\}}"
  local subject="${4:-}"
  local content="${5:-}"
  [ -n "$subject" ] || subject="$event:${task:-system}"

  local idem
  idem=$(idem_key chanakya inbox-sweep "$subject" "$event:$content")
  event_idem_seen "$idem" && return 0
  emit_event_keyed chanakya inbox-sweep "$event" "$task" "$data" --idem-key "$idem" >/dev/null || true
}

task_followup_seen() {
  local debrief_uuid="${1:?task_followup_seen <debrief-id> <index>}"
  local index="${2:?}"
  [ -d "$TASKS_DIR" ] || return 1
  local f
  for f in "$TASKS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    grep -F "source_debrief: \"$debrief_uuid\"" "$f" >/dev/null 2>&1 || continue
    grep -F "source_follow_up_index: $index" "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

argus_infra_reason() {
  case "$1" in
    unknown_host|missing_manifest|missing_spawn_command|secret_scope_floor_unmet|mktemp_failed|validator_unavailable|handoff_schema_violation)
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---- debrief -------------------------------------------------------------
ingest_debrief() {
  local argus_exempt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --argus-exempt) argus_exempt=1; shift ;;
      *) printf 'ingest_debrief: unknown flag %s\n' "$1" >&2; return 2 ;;
    esac
  done

  local debrief_uuid="" legacy_task_id="" merge_sha="" task_uuid="" event_task=""
  local argus_status="not-invoked" review_uuid="" follow_ups_count=0
  local to_state="merged" errors_present="" mode="task" report_state=""
  local merged_into="" argus_reason="" argus_notes=""

  command -v yq >/dev/null 2>&1 || { printf 'ingest_debrief: yq required\n' >&2; return 2; }
  yaml_parse_check "$SRC" sweep-ingest-debrief || return 2
  debrief_uuid=$(yq -r '.id // ""' "$SRC" 2>/dev/null || echo "")
  task_uuid=$(yq -r '.task_id // ""' "$SRC" 2>/dev/null || echo "")
  [ "$task_uuid" = "null" ] && task_uuid=""
  legacy_task_id=$(yq -r '.legacy_task_id // ""' "$SRC" 2>/dev/null || echo "")
  merge_sha=$(yq -r '.branch.merge_sha // ""' "$SRC" 2>/dev/null || echo "")
  merged_into=$(yq -r '.branch.merged_into // ""' "$SRC" 2>/dev/null || echo "")
  [ "$merged_into" = "null" ] && merged_into=""
  argus_status=$(yq -r '.argus_review.status // "not-invoked"' "$SRC" 2>/dev/null || echo "not-invoked")
  argus_reason=$(yq -r '.argus_review.reason // ""' "$SRC" 2>/dev/null || echo "")
  [ "$argus_reason" = "null" ] && argus_reason=""
  argus_notes=$(yq -r '.argus_review.notes // ""' "$SRC" 2>/dev/null || echo "")
  [ "$argus_notes" = "null" ] && argus_notes=""
  review_uuid=$(yq -r '.argus_review.review_id // ""' "$SRC" 2>/dev/null || echo "")
  [ "$review_uuid" = "null" ] && review_uuid=""
  follow_ups_count=$(yq -r '.follow_ups // [] | length' "$SRC" 2>/dev/null || echo 0)
  mode=$(yq -r '.mode // "task"' "$SRC" 2>/dev/null || echo task)
  report_state=$(yq -r '.report_state // "done_with_concerns"' "$SRC" 2>/dev/null || echo "done_with_concerns")
  [ "$report_state" = "null" ] && report_state="done_with_concerns"
  case "$report_state" in
    done|done_with_concerns) to_state="merged" ;;
    blocked)                to_state="blocked" ;;
    needs_context)          to_state="blocked" ;;
    *)                      report_state="done_with_concerns"; to_state="merged" ;;
  esac
  # When errors are present, route the task to `blocked` even if an older
  # debrief omitted report_state.
  errors_present=$(yq -r '.errors // [] | length' "$SRC" 2>/dev/null || echo 0)
  if [ "${errors_present:-0}" -gt 0 ]; then
    to_state="blocked"
    report_state="blocked"
  fi

  # Resolve task UUID when we only have a legacy id (YAML debriefs may carry
  # either or both; legacy debriefs carry only legacy).
  if [ -z "$task_uuid" ] && [ -n "$legacy_task_id" ]; then
    task_uuid=$(resolve_task_uuid_by_legacy_id "$legacy_task_id")
  fi
  event_task="${legacy_task_id:-$task_uuid}"

  # Task-side state + link mutations. Direct-debriefs (no task_uuid) skip
  # these — the debrief stands alone per inbox-sweep.md §uniform-ingest.
  if [ -n "$task_uuid" ]; then
    transition_task_state "$task_uuid" "$to_state" chanakya "debrief ingested" || true
    if [ -n "$debrief_uuid" ]; then
      set_task_link "$task_uuid" debrief "$debrief_uuid" || true
    fi
    if [ -n "$review_uuid" ]; then
      append_task_link "$task_uuid" reviews "$review_uuid" || true
    fi
  fi

  # Mint follow-up tasks from the debrief's array. For direct-debriefs, pass
  # source_debrief= so the new task can be traced back even without a parent.
  follow_ups_minted=0
  follow_ups_failed=0
  if [ "${follow_ups_count:-0}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$follow_ups_count" ]; do
      title=$(yq -r ".follow_ups[$i].title // .follow_ups[$i].summary // .follow_ups[$i].description // .follow_ups[$i] // \"\"" "$SRC" 2>/dev/null | head -c 200)
      if [ -z "$title" ] || [ "$title" = "null" ]; then
        follow_ups_failed=$(( follow_ups_failed + 1 ))
        fail_data=$(printf '{"debrief_id":"%s","follow_up_index":%s,"reason":"follow_up_title_missing"}' \
          "$(_json_escape "$debrief_uuid")" "$i")
        emit_reconcile_event follow_up_mint_failed "$event_task" "$fail_data" "${debrief_uuid:-$SRC}" "follow-up:$i:title-missing"
        i=$((i+1))
        continue
      fi
      if [ -n "$debrief_uuid" ] && task_followup_seen "$debrief_uuid" "$i"; then
        i=$(( i + 1 ))
        continue
      fi
      new_uuid=$(mint_uuidv7)
      if write_task_artifact "$new_uuid" proposed "$title" \
          "source_debrief=$debrief_uuid" \
          "source_task=${legacy_task_id:-$task_uuid}" \
          "source_follow_up_index=$i" >/dev/null 2>&1; then
        follow_ups_minted=$(( follow_ups_minted + 1 ))
      else
        follow_ups_failed=$(( follow_ups_failed + 1 ))
        fail_data=$(printf '{"debrief_id":"%s","follow_up_index":%s,"reason":"write_task_artifact_failed"}' \
          "$(_json_escape "$debrief_uuid")" "$i")
        emit_reconcile_event follow_up_mint_failed "$event_task" "$fail_data" "${debrief_uuid:-$SRC}" "follow-up:$i:failed"
      fi
      i=$(( i + 1 ))
    done
  fi

  # Flip the debrief's state `emitted → ingested`. lib-ledger has no
  # transition_debrief_state helper today (debriefs have no state-machine
  # doc; the state field was added post-hoc in debrief@2.0.1). Direct yq
  # edit mirrors the mode-pack's existing idiom.
  if command -v yq >/dev/null 2>&1; then
    ts=$(iso_ts_now)
    yq -i ".state = \"ingested\" | .updated_at = \"$ts\"" "$SRC" 2>/dev/null || true
  fi

  # Main event. Task field is the legacy id when present (readable across
  # events tail) else the UUID; empty for direct-debriefs per the contract.
  argus_skip_bool="false"
  [ "$argus_status" = "not-invoked" ] && argus_skip_bool="true"
  data=$(printf '{"follow_ups_minted":%s,"follow_ups_failed":%s,"argus_skip_detected":%s,"mode":"%s","report_state":"%s"}' \
    "$follow_ups_minted" "$follow_ups_failed" "$argus_skip_bool" "$(_json_escape "$mode")" "$(_json_escape "$report_state")")
  emit_reconcile_event debrief_ingested "$event_task" "$data" "${debrief_uuid:-$SRC}" "state=ingested;report_state=$report_state"

  if [ -n "$merge_sha" ]; then
    completed_data=$(printf '{"merge_sha":"%s","source":"debrief_reconcile","debrief_id":"%s"}' \
      "$(_json_escape "$merge_sha")" "$(_json_escape "$debrief_uuid")")
    emit_reconcile_event task_completed "$event_task" "$completed_data" "${debrief_uuid:-$SRC}" "task-completed:$merge_sha"
  fi

  case "$report_state" in
    done_with_concerns)
      concern_data=$(printf '{"debrief_id":"%s","report_state":"done_with_concerns","reason":"debrief_report_state"}' \
        "$(_json_escape "$debrief_uuid")")
      emit_reconcile_event debrief_concerns "$event_task" "$concern_data" "${debrief_uuid:-$SRC}" "done_with_concerns"
      ;;
    needs_context)
      context_data=$(printf '{"debrief_id":"%s","report_state":"needs_context","reason":"debrief_report_state"}' \
        "$(_json_escape "$debrief_uuid")")
      emit_reconcile_event debrief_needs_context "$event_task" "$context_data" "${debrief_uuid:-$SRC}" "needs_context"
      ;;
  esac

  # review_pending — unless the caller flagged `--argus-exempt` (the mode
  # pack matches the exemption list in prose; we just honor the flag), or a
  # structured waive is active for the argus gate (the "stop nagging" half of
  # issue #83 / #103). Counter bump stays unconditional so active waives
  # continue to accumulate merges even while suppression is on.
  if [ "$argus_exempt" = "0" ] && [ "$argus_status" = "not-invoked" ]; then
    if is_waive_active argus 2>/dev/null; then
      bump_waive_counter argus 2>/dev/null || true
    else
      esc_sha=${merge_sha//\"/\\\"}
      pending_data=$(printf '{"merge_sha":"%s","reason":"argus_skipped_in_debrief"}' "$esc_sha")
      emit_reconcile_event review_pending "$event_task" "$pending_data" "${debrief_uuid:-$SRC}" "review-pending:$merge_sha"
      bump_waive_counter argus 2>/dev/null || true
    fi
  fi

  if [ "$argus_status" = "not-invoked" ] && argus_infra_reason "$argus_reason"; then
    gate_data=$(printf '{"stage":"quality","idem_key":"%s","reason":"%s","host":"%s","source":"debrief_reconcile"}' \
      "$(_json_escape "debrief:${debrief_uuid:-$SRC}:argus_gate_skipped")" \
      "$(_json_escape "$argus_reason")" \
      "$(_json_escape "${argus_notes:-unknown}")")
    emit_reconcile_event argus_gate_skipped "$event_task" "$gate_data" "${debrief_uuid:-$SRC}" "argus-gate-skipped:$argus_reason"
  fi

  # Protected-branch ungated-merge audit (#108). Fires iff a debrief records a
  # merge into a policy-protected integration branch (main, master, release/*,
  # v/*, hotfix/*) with argus_review.status=not-invoked AND no external-review
  # citation in argus_review.reason / .notes. External-agent peer reviews are
  # fine — they just have to show their work with a URL or `#<issue-or-pr>`.
  # Post-fact audit, not a pre-merge block; the latter requires git hooks in
  # the target repo and is tracked separately.
  if [ "$argus_status" = "not-invoked" ] && [ -n "$merged_into" ] && is_protected_branch "$merged_into"; then
    combined_citation="$argus_reason $argus_notes"
    case "$combined_citation" in
      *https://*|*http://*|*\#[0-9]*) ;;  # external citation present — ok
      *)
        esc_sha=${merge_sha//\"/\\\"}
        esc_branch=${merged_into//\"/\\\"}
        esc_mode=${mode//\"/\\\"}
        audit_data=$(printf '{"merge_sha":"%s","merged_into":"%s","mode":"%s","reason":"argus_not_invoked_no_citation"}' \
          "$esc_sha" "$esc_branch" "$esc_mode")
        emit_reconcile_event direct_main_ungated_merge "$event_task" "$audit_data" "${debrief_uuid:-$SRC}" "ungated:$merged_into:$merge_sha"
        ;;
    esac
  fi
}

# ---- build-check ---------------------------------------------------------
ingest_build_check() {
  local result="" broken_sha=""
  command -v yq >/dev/null 2>&1 || return 2
  yaml_parse_check "$SRC" sweep-ingest-build-check || return 2
  result=$(yq -r '.result // .build_gate // ""' "$SRC" 2>/dev/null || echo "")
  broken_sha=$(yq -r '.broken_commit_sha // ""' "$SRC" 2>/dev/null || echo "")

  # Normalize: `green|pass|full-green` → green; `red|fail` → red; else inconclusive.
  case "$result" in
    green|pass|full-green) result=green ;;
    red|fail)              result=red ;;
    inconclusive|'')       result=inconclusive ;;
    *)                     result=inconclusive ;;
  esac

  case "$result" in
    green)
      # Canonical YAML write — projector regenerates the master-plan section
      # on end-of-run.
      build_debt_reset_green "" "${broken_sha:-}" >/dev/null 2>&1 || true
      ;;
    red)
      # File a P0 fix task referencing the broken commit. TBUILD-N allocator
      # remains here (operates on the task YAML directory; build-debt YAML's
      # next_tbuild_n is for threshold-script's mint, not this red path).
      next_n=1
      if [ -d "$TASKS_DIR" ]; then
        max_n=$(grep -hE '^legacy_task_id: *"?TBUILD-' "$TASKS_DIR"/*.yaml 2>/dev/null \
          | sed -E 's/[^0-9]+//g' | sort -n | tail -1)
        [ -n "$max_n" ] && next_n=$(( max_n + 1 ))
      fi
      fix_uuid=$(mint_uuidv7)
      fix_title="Fix red build (build-check broke at ${broken_sha:-HEAD})"
      write_task_artifact "$fix_uuid" proposed "$fix_title" \
        type=build-check priority=P0 source=build-check \
        "legacy_task_id=TBUILD-$next_n" "broken_commit_sha=$broken_sha" \
        >/dev/null 2>&1 || true
      # Persist the block flag so subsequent briefs refuse until cleared.
      mkdir -p "$PROJECT_ROOT/.runtime/state" 2>/dev/null || true
      printf 'red_build: true\nbroken_commit_sha: %s\nset_at: %s\n' \
        "${broken_sha:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$PROJECT_ROOT/.runtime/state/build_debt_blocked" 2>/dev/null || true
      # Canonical YAML annotation — projector renders the markdown section.
      build_debt_annotate_red "${broken_sha:-unknown}" "TBUILD-$next_n" >/dev/null 2>&1 || true
      ;;
    inconclusive)
      printf 'inconclusive build-check — leaving counter (source=%s)\n' "$SRC" >&2
      ;;
  esac

  # YAML build-check debriefs flip to ingested via inline yq (no state machine
  # for build-check specifically — symmetric with debrief handler).
  yq -i ".state = \"ingested\" | .updated_at = \"$(iso_ts_now)\"" "$SRC" 2>/dev/null || true
}

# ---- release -------------------------------------------------------------
ingest_release() {
  local tag="" build_num="" channel="" version="" head_sha="" tasks_csv=""
  command -v yq >/dev/null 2>&1 || return 2
  yaml_parse_check "$SRC" sweep-ingest-release || return 2
  tag=$(yq -r '.tag // ""' "$SRC" 2>/dev/null || echo "")
  build_num=$(yq -r '.build_number // ""' "$SRC" 2>/dev/null || echo "")
  channel=$(yq -r '.channel // ""' "$SRC" 2>/dev/null || echo "")
  version=$(yq -r '.version // ""' "$SRC" 2>/dev/null || echo "")
  head_sha=$(yq -r '.commit_sha // ""' "$SRC" 2>/dev/null || echo "")
  tasks_csv=$(yq -r '.tasks // [] | join(",")' "$SRC" 2>/dev/null || echo "")

  # Existence check — if a release with this tag already exists we just flip
  # state and move on. Prevents duplicate legacy Release Log rows and
  # double-linking the covered tasks.
  existing_uuid=""
  if [ -n "$tag" ] && [ -d "$RELEASES_DIR" ] && command -v yq >/dev/null 2>&1; then
    existing_uuid=$(grep -lE "^tag: *\"?${tag}\"?$" "$RELEASES_DIR"/*.yaml 2>/dev/null \
      | head -1 | xargs -I{} basename {} .yaml 2>/dev/null)
  fi

  if [ -z "$existing_uuid" ]; then
    release_uuid=$(mint_uuidv7)
    write_release_artifact "$release_uuid" "${channel:-testflight}" \
      "${version:-0.0.0}" "${build_num:-0}" "${tag:-unknown}" "${tasks_csv:-}" \
      >/dev/null 2>&1 || true
  else
    release_uuid="$existing_uuid"
  fi

  # Back-reference: tag each covered task's links.release. The master-plan
  # `- **Released in:** TF-N` annotation is rendered by render-master-plan.sh
  # from these links every sweep — no inline awk write here. (Closes the
  # unguarded-writer (W!) finding from audits/245-A1-reader-audit.md.)
  if [ -n "$tasks_csv" ]; then
    IFS=',' read -r -a tarr <<< "$tasks_csv"
    for t in "${tarr[@]}"; do
      t=$(printf '%s' "$t" | tr -d ' ')
      [ -z "$t" ] && continue
      tu=$(resolve_task_uuid_by_legacy_id "$t")
      [ -n "$tu" ] && set_task_link "$tu" release "$release_uuid" || true
    done
  fi

  # State transition — idempotent on re-run (no-op when already released).
  transition_release_state "$release_uuid" released chanakya "debrief ingested" || true

  command -v yq >/dev/null 2>&1 && \
    yq -i ".state = \"ingested\" | .updated_at = \"$(iso_ts_now)\"" "$SRC" 2>/dev/null || true
}

case "$SUBCMD" in
  debrief)     ingest_debrief     "$@" ;;
  build-check) ingest_build_check "$@" ;;
  release)     ingest_release     "$@" ;;
esac
rc=$?

# Re-render the projected master-plan markdown from YAML sources after every
# successful ingest. Idempotent — same inputs produce byte-identical output.
# Failure here doesn't fail the ingest (the YAML write is canonical; the
# markdown is a derivative).
if [ "$rc" = "0" ]; then
  bash "$SCRIPT_DIR/render-master-plan.sh" >/dev/null 2>&1 || true
fi

exit "$rc"
