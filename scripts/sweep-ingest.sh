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

# `file is yaml?` — trailing `.yaml` distinguishes post-migration artifacts
# from legacy markdown debriefs in the same mixed inbox. Every subcommand
# branches on this flag to parse the right shape.
is_yaml=0
case "$SRC" in
  *.yaml) is_yaml=1 ;;
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

# ---- debrief -------------------------------------------------------------
ingest_debrief() {
  local argus_exempt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --argus-exempt) argus_exempt=1; shift ;;
      *) printf 'ingest_debrief: unknown flag %s\n' "$1" >&2; return 2 ;;
    esac
  done

  local debrief_uuid="" legacy_task_id="" merge_sha="" task_uuid=""
  local argus_status="not-invoked" review_uuid="" follow_ups_count=0
  local to_state="merged" errors_present="" mode="task"
  local merged_into="" argus_reason="" argus_notes=""

  if [ "$is_yaml" = "1" ]; then
    command -v yq >/dev/null 2>&1 || { printf 'ingest_debrief: yq required for YAML surface\n' >&2; return 2; }
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
    # When errors are present (debrief carries a non-empty errors array or
    # build_gate: red), route the task to `blocked` instead of `merged`.
    errors_present=$(yq -r '.errors // [] | length' "$SRC" 2>/dev/null || echo 0)
    if [ "${errors_present:-0}" -gt 0 ]; then
      to_state="blocked"
    fi
  else
    # Legacy markdown — extract the minimum needed: task id from filename,
    # merge SHA + argus verdict from headers. Mode is always `task` for legacy.
    legacy_task_id=$(basename "$SRC" | sed -n 's/\(.*\)-debrief\.md$/\1/p')
    merge_sha=$(grep -m1 '^Merge SHA:' "$SRC" 2>/dev/null | awk '{print $3}')
    [ -z "$merge_sha" ] && merge_sha=$(grep -m1 '^- *\*\*Merge SHA' "$SRC" 2>/dev/null | sed -E 's/.*:[[:space:]]*//')
    if grep -qiE 'argus[[:space:]]*:[[:space:]]*(not invoked|skipped|bypassed|did not run)' "$SRC" 2>/dev/null; then
      argus_status="not-invoked"
    elif grep -qiE '^##[[:space:]]*Argus Review' "$SRC" 2>/dev/null; then
      # Best-effort verdict sniff — anything else means Argus did run.
      argus_status="approved"
    fi
    follow_ups_count=$(awk '/^## Follow-up Tasks/{in=1; next} /^## /{in=0} in && /^- /{n++} END{print n+0}' "$SRC" 2>/dev/null || echo 0)
  fi

  # Resolve task UUID when we only have a legacy id (YAML debriefs may carry
  # either or both; legacy debriefs carry only legacy).
  if [ -z "$task_uuid" ] && [ -n "$legacy_task_id" ]; then
    task_uuid=$(resolve_task_uuid_by_legacy_id "$legacy_task_id")
  fi

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
  if [ "$is_yaml" = "1" ] && [ "${follow_ups_count:-0}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$follow_ups_count" ]; do
      title=$(yq -r ".follow_ups[$i] // \"\"" "$SRC" 2>/dev/null | head -c 200)
      [ -z "$title" ] && { i=$((i+1)); continue; }
      new_uuid=$(mint_uuidv7)
      if [ -z "$task_uuid" ] && [ -n "$debrief_uuid" ]; then
        write_task_artifact "$new_uuid" proposed "$title" \
          "source_debrief=$debrief_uuid" >/dev/null 2>&1 || true
      else
        write_task_artifact "$new_uuid" proposed "$title" \
          "source_task=${legacy_task_id:-$task_uuid}" >/dev/null 2>&1 || true
      fi
      follow_ups_minted=$(( follow_ups_minted + 1 ))
      i=$(( i + 1 ))
    done
  fi

  # Flip the debrief's state `emitted → ingested`. lib-ledger has no
  # transition_debrief_state helper today (debriefs have no state-machine
  # doc; the state field was added post-hoc in debrief@2.0.1). Direct yq
  # edit mirrors the mode-pack's existing idiom.
  if [ "$is_yaml" = "1" ] && command -v yq >/dev/null 2>&1; then
    ts=$(iso_ts_now)
    yq -i ".state = \"ingested\" | .updated_at = \"$ts\"" "$SRC" 2>/dev/null || true
  fi

  # Legacy cleanup — move source to processed/ so the next sweep doesn't
  # re-pick it up. Idempotent inside lib-ledger helper.
  if [ "$is_yaml" = "0" ]; then
    legacy_inbox_move_to_processed "$(basename "$SRC")" || true
  fi

  # Main event. Task field is the legacy id when present (readable across
  # events tail) else the UUID; empty for direct-debriefs per the contract.
  argus_skip_bool="false"
  [ "$argus_status" = "not-invoked" ] && argus_skip_bool="true"
  data=$(printf '{"follow_ups_minted":%s,"argus_skip_detected":%s,"mode":"%s"}' \
    "$follow_ups_minted" "$argus_skip_bool" "$mode")
  event_task="${legacy_task_id:-$task_uuid}"
  emit_event_keyed chanakya inbox-sweep debrief_ingested "$event_task" "$data" >/dev/null || true

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
      emit_event_keyed chanakya inbox-sweep review_pending "$event_task" "$pending_data" >/dev/null || true
      bump_waive_counter argus 2>/dev/null || true
    fi
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
        emit_event_keyed chanakya inbox-sweep direct_main_ungated_merge "$event_task" "$audit_data" >/dev/null || true
        ;;
    esac
  fi
}

# ---- build-check ---------------------------------------------------------
ingest_build_check() {
  local result="" broken_sha=""
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  if [ "$is_yaml" = "1" ]; then
    command -v yq >/dev/null 2>&1 || return 2
    yaml_parse_check "$SRC" sweep-ingest-build-check || return 2
    result=$(yq -r '.result // .build_gate // ""' "$SRC" 2>/dev/null || echo "")
    broken_sha=$(yq -r '.broken_commit_sha // ""' "$SRC" 2>/dev/null || echo "")
  else
    # Legacy header: `result: pass|fail` or `Result: green|red`.
    result=$(grep -m1 -iE '^result:|^Result:' "$SRC" 2>/dev/null | awk -F': *' '{print tolower($2)}')
    broken_sha=$(grep -m1 '^Breaking commit:' "$SRC" 2>/dev/null | awk '{print $3}')
  fi

  # Normalize: `green|pass|full-green` → green; `red|fail` → red; else inconclusive.
  case "$result" in
    green|pass|full-green) result=green ;;
    red|fail)              result=red ;;
    inconclusive|'')       result=inconclusive ;;
    *)                     result=inconclusive ;;
  esac

  case "$result" in
    green)
      # Reset the Build Debt counter in-place, scoped to the `## Build Debt`
      # section. Matches the awk idiom used by legacy_master_plan_set_status
      # (bounded by the next `##` heading).
      if [ -f "$master" ]; then
        tmp="$master.tmp.$$"
        awk '
          BEGIN { in_block=0 }
          /^## Build Debt/ { in_block=1; print; next }
          in_block && /^## / { in_block=0; print; next }
          in_block && /^- Counter:/ {
            sub(/Counter: *[0-9]+/, "Counter: 0")
            print; next
          }
          { print }
        ' "$master" > "$tmp" 2>/dev/null && mv "$tmp" "$master" || rm -f "$tmp"
      fi
      ;;
    red)
      # File a P0 fix task referencing the broken commit. Next TBUILD
      # sequence number is tracked via counter in the master plan (best
      # effort — legacy id resolves as TBUILD-N where N is the next free
      # integer based on existing files).
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
      # Annotate the debt block with the breaking commit for visibility.
      if [ -f "$master" ]; then
        tmp="$master.tmp.$$"
        awk -v sha="${broken_sha:-unknown}" '
          BEGIN { in_block=0; annotated=0 }
          /^## Build Debt/ { in_block=1; print; next }
          in_block && /^## / { in_block=0; print; next }
          in_block && /^- Counter:/ {
            line=$0
            t=line; sub(/^.*Counter: */, "", t); sub(/ .*$/, "", t); n=t+0
            sub(/Counter: *[0-9]+/, sprintf("Counter: %d", n+1), line)
            print line
            next
          }
          in_block && /^- Broken commit:/ {
            sub(/Broken commit:.*/, "Broken commit: " sha)
            annotated=1
            print; next
          }
          in_block && !annotated && /^- Blocked by:/ {
            sub(/Blocked by:.*/, "Blocked by: TBUILD-fix")
            print
            print "- Broken commit: " sha
            annotated=1
            next
          }
          { print }
        ' "$master" > "$tmp" 2>/dev/null && mv "$tmp" "$master" || rm -f "$tmp"
      fi
      ;;
    inconclusive)
      printf 'inconclusive build-check — leaving counter (source=%s)\n' "$SRC" >&2
      ;;
  esac

  # Move the legacy source to processed/ so it isn't re-picked next sweep.
  if [ "$is_yaml" = "0" ]; then
    legacy_inbox_move_to_processed "$(basename "$SRC")" || true
  else
    # YAML build-check debriefs flip to ingested via inline yq (no state
    # machine for build-check specifically — symmetric with debrief handler).
    command -v yq >/dev/null 2>&1 && \
      yq -i ".state = \"ingested\" | .updated_at = \"$(iso_ts_now)\"" "$SRC" 2>/dev/null || true
  fi
}

# ---- release -------------------------------------------------------------
ingest_release() {
  local tag="" build_num="" channel="" version="" head_sha="" tasks_csv=""
  if [ "$is_yaml" = "1" ]; then
    command -v yq >/dev/null 2>&1 || return 2
    yaml_parse_check "$SRC" sweep-ingest-release || return 2
    tag=$(yq -r '.tag // ""' "$SRC" 2>/dev/null || echo "")
    build_num=$(yq -r '.build_number // ""' "$SRC" 2>/dev/null || echo "")
    channel=$(yq -r '.channel // ""' "$SRC" 2>/dev/null || echo "")
    version=$(yq -r '.version // ""' "$SRC" 2>/dev/null || echo "")
    head_sha=$(yq -r '.commit_sha // ""' "$SRC" 2>/dev/null || echo "")
    tasks_csv=$(yq -r '.tasks // [] | join(",")' "$SRC" 2>/dev/null || echo "")
  else
    # Legacy markdown header shape: `Build number: 3031`, `Version: 1.4.2`,
    # `Distribution: testflight-release`, `Git tag: tf-3031`, etc.
    build_num=$(grep -m1 '^Build number:' "$SRC" 2>/dev/null | awk -F': *' '{print $2}')
    version=$(grep -m1 '^Version:' "$SRC" 2>/dev/null | awk -F': *' '{print $2}')
    tag=$(grep -m1 -E '^(Git )?tag:' "$SRC" 2>/dev/null | awk -F': *' '{print $2}')
    head_sha=$(grep -m1 -E '^HEAD( SHA)?:' "$SRC" 2>/dev/null | awk -F': *' '{print $2}')
    if grep -qi 'Distribution.*testflight\|^Type: *testflight-release' "$SRC" 2>/dev/null; then
      channel=testflight
    else
      channel=appstore
    fi
    tasks_csv=$(grep -m1 -E '^Covers?:' "$SRC" 2>/dev/null | awk -F': *' '{print $2}' | tr -d ' ')
  fi

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

  # Back-reference: tag each covered task's links.release + legacy master-
  # plan `Released in:` row. The master-plan edit is inline here since the
  # lib-ledger helper doesn't exist yet.
  if [ -n "$tasks_csv" ]; then
    tag_label="TF-$build_num"
    [ "$channel" = "appstore" ] && tag_label="AS-$build_num"
    IFS=',' read -r -a tarr <<< "$tasks_csv"
    for t in "${tarr[@]}"; do
      t=$(printf '%s' "$t" | tr -d ' ')
      [ -z "$t" ] && continue
      tu=$(resolve_task_uuid_by_legacy_id "$t")
      [ -n "$tu" ] && set_task_link "$tu" release "$release_uuid" || true
      # Legacy master-plan `Released in:` annotation, scoped to this task's
      # section. Comma-separated if a row already has a value (multi-release
      # tasks accrue labels).
      master="$PROJECT_ROOT/plans/chanakya-master.md"
      if [ -f "$master" ]; then
        tmp="$master.tmp.$$"
        awk -v id="$t" -v label="$tag_label" '
          BEGIN { in_section=0; annotated=0 }
          /^### / {
            if ($2 == id) in_section=1
            else {
              if (in_section && !annotated) print "- **Released in:** " label
              in_section=0
            }
            print; next
          }
          /^## / {
            if (in_section && !annotated) print "- **Released in:** " label
            in_section=0
            print; next
          }
          in_section && /^- \*\*Released in:\*\*/ {
            # Append label idempotently — skip if already present.
            if (index($0, label) == 0) {
              sub(/$/, ", " label)
            }
            annotated=1
            print; next
          }
          { print }
          END { if (in_section && !annotated) print "- **Released in:** " label }
        ' "$master" > "$tmp" 2>/dev/null && mv "$tmp" "$master" || rm -f "$tmp"
      fi
    done
  fi

  # State transition — idempotent on re-run (no-op when already released).
  transition_release_state "$release_uuid" released chanakya "debrief ingested" || true

  # Legacy cleanup.
  if [ "$is_yaml" = "0" ]; then
    legacy_inbox_move_to_processed "$(basename "$SRC")" || true
  else
    command -v yq >/dev/null 2>&1 && \
      yq -i ".state = \"ingested\" | .updated_at = \"$(iso_ts_now)\"" "$SRC" 2>/dev/null || true
  fi
}

case "$SUBCMD" in
  debrief)     ingest_debrief     "$@" ;;
  build-check) ingest_build_check "$@" ;;
  release)     ingest_release     "$@" ;;
esac
rc=$?
exit "$rc"
