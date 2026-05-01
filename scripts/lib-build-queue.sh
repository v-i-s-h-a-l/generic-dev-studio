#!/usr/bin/env bash
# lib-build-queue.sh — shared priority-queue primitives for the per-node build lock.
#
# Used by task-build-gate.sh (Achilles task builds) and studio-tf-push.sh
# (release builds) so both participate in the same serialization queue.
#
# Queue lives at: ~/.dev-studio/.runtime/build-queue/<node-id>/
# Each waiter writes one file; the sort order determines who runs next.
#
# Filename format (priority-aware):
#   <rank>-<enqueued_at>-<pid>-<task-id>.json
#   rank: 0=release, 1=task, 2=background
#
# Lexical sort: rank prefix ensures release sorts ahead of task entries
# regardless of absolute arrival time. Within same rank, older enqueued_at
# wins (FIFO). Old entries without rank prefix sort between release and task
# ('1...') or after background ('2...') — they act like task priority, which
# is correct for backward compat during the transition.
#
# Provided functions:
#   bq_rank <priority>          → prints rank digit (0/1/2)
#   bq_node_slots <node>        → prints configured parallel slot count
#   bq_enqueue <dir> <id> <priority> [role] [secret_scope]
#                               → writes entry, prints path
#   bq_wait <dir> <entry> <slots> <timeout_s> <task> <node>
#                               → waits in priority order; returns 0 or 3
#   bq_acquire_slot_lock <lock_base> <slots> <timeout_s>
#                               → acquires slot-<n> lock; prints path
#   bq_release_slot_lock <lock_path>
#                               → releases acquired slot lock
#   bq_release <entry>          → removes entry (idempotent)

# bq_rank — convert priority string to sort rank digit
bq_rank() {
  case "${1:-task}" in
    release)    printf '0' ;;
    task)       printf '1' ;;
    background) printf '2' ;;
    *)          printf '1' ;;
  esac
}

# bq_node_slots <node_id>
# Reads the per-node parallel slot count from nodes.json. Synthetic `local`
# remains single-slot because it has no registry entry; malformed values
# collapse to 1 so a bad registry cannot over-admit builds.
bq_node_slots() {
  local node="${1:-local}" n registry
  if [ "$node" = "local" ]; then
    printf '1\n'
    return 0
  fi
  if command -v resolve_runtime_global >/dev/null 2>&1; then
    registry="$(resolve_runtime_global)/nodes.json"
  else
    registry="$HOME/.dev-studio/.runtime/nodes.json"
  fi
  n=1
  if [ -r "$registry" ] && command -v jq >/dev/null 2>&1; then
    n=$(jq -r --arg id "$node" '.nodes[]? | select(.id == $id) | .parallel_build_slots // 1' "$registry" 2>/dev/null)
  fi
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -lt 1 ] && n=1
  printf '%s\n' "$n"
}

_bq_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_bq_entry_field() {
  local field="$1" entry="$2" value=""
  if [ -r "$entry" ] && command -v jq >/dev/null 2>&1; then
    value=$(jq -r --arg f "$field" '.[$f] // empty' "$entry" 2>/dev/null || printf '')
  fi
  if [ -z "$value" ] && [ -r "$entry" ]; then
    value=$(grep -o "\"$field\":\"[^\"]*\"" "$entry" 2>/dev/null | sed "s/\"$field\":\"//;s/\"//" || printf '')
  fi
  printf '%s\n' "$value"
}

# bq_enqueue <queue_dir> <id> <priority> [role] [secret_scope]
# Writes queue entry; prints entry path on stdout.
bq_enqueue() {
  local qdir="${1:?bq_enqueue: queue_dir required}"
  local task="${2:?bq_enqueue: task_id required}"
  local pri="${3:-task}"
  local role="${4:-xcodebuild}"
  local secret_scope="${5:-none}"
  local rank ts entry
  rank=$(bq_rank "$pri")
  ts=$(date -u +%s)
  mkdir -p "$qdir" 2>/dev/null || { printf 'bq_enqueue: mkdir %s failed\n' "$qdir" >&2; return 2; }
  entry="$qdir/$(printf '%s-%010d-%d-%s.json' "$rank" "$ts" "$$" "$task")"
  printf '{"id":"%s","priority":"%s","enqueued_at":%s,"pid":%s,"role":"%s","secret_scope":"%s"}\n' \
    "$(_bq_json_escape "$task")" "$(_bq_json_escape "$pri")" "$ts" "$$" \
    "$(_bq_json_escape "$role")" "$(_bq_json_escape "$secret_scope")" > "$entry" \
    || { printf 'bq_enqueue: write %s failed\n' "$entry" >&2; return 2; }
  printf '%s\n' "$entry"
}

# bq_wait <queue_dir> <entry_path> <slots> <timeout_s> <task_id> <node_id>
# Blocks until <entry_path> is in the first <slots> positions (by sort order).
# Emits build_queue_granted + build_queue_promoted (if applicable) on success.
# Returns 0 on success, 3 on timeout. Emits build_check_failed on timeout if
# _emit_terminal is defined (task-build-gate contract) — otherwise just exits 3.
bq_wait() {
  local qdir="${1:?}" entry="${2:?}" slots="${3:-1}" timeout_s="${4:-1800}"
  local task_id="${5:-unknown}" node_id="${6:-local}"
  local wait_s=0 backoff=10

  # GC stale entries (>45 min) before entering the wait.
  _bq_gc() { find "$qdir" -maxdepth 1 -type f -name '*.json' -mmin +45 -delete 2>/dev/null || true; }
  _bq_gc

  while :; do
    _bq_gc
    if find "$qdir" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
         | sort | head -n "$slots" | grep -qxF "$entry"; then
      break
    fi
    if [ "$wait_s" -ge "$timeout_s" ]; then
      local head
      head=$(find "$qdir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | head -1)
      printf 'bq_wait: queue wait exceeded %ss (slots=%s head=%s)\n' "$timeout_s" "$slots" "$head" >&2
      if command -v _emit_terminal >/dev/null 2>&1; then
        local data
        data=$(printf '{"mode":"full-green","reason":"queue_locked_out","waited_s":%s,"slots":%s}' \
          "$wait_s" "$slots")
        _emit_terminal build_check_failed "$data" 2>/dev/null || true
      fi
      bq_release "$entry"
      return 3
    fi
    sleep "$backoff"
    wait_s=$((wait_s + backoff))
  done

  # Emit build_queue_granted with wait time + priority metadata.
  local pri
  pri=$(_bq_entry_field priority "$entry")
  [ -z "$pri" ] && pri=task
  if command -v emit_event_keyed >/dev/null 2>&1; then
    local granted_data
    granted_data=$(printf '{"node":"%s","task":"%s","priority":"%s","waited_s":%s}' \
      "$node_id" "$task_id" "$pri" "$wait_s")
    emit_event_keyed achilles task build_queue_granted "$task_id" "$granted_data" >/dev/null 2>&1 || true
  fi

  # Emit build_queue_promoted if we jumped ahead of any older lower-priority entries.
  _bq_emit_promoted "$qdir" "$entry" "$pri" "$task_id" "$node_id" "$wait_s"
}

# _bq_emit_promoted — internal: emit build_queue_promoted if we jumped ahead.
# A "promotion" means our entry has a lower rank (higher priority) AND at least
# one other entry in the queue has a higher rank but was enqueued before us.
_bq_emit_promoted() {
  local qdir="$1" entry="$2" our_pri="$3" task="$4" node="$5" waited="$6"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local our_rank our_ts basename
  basename=$(basename "$entry")
  our_rank=$(printf '%s' "$basename" | cut -d- -f1)
  our_ts=$(printf '%s' "$basename" | cut -d- -f2)

  # Only release priority can have promoted past others.
  [ "$our_rank" = "0" ] || return 0

  local skipped=0
  local skipped_tasks=""
  while IFS= read -r f; do
    [ "$f" = "$entry" ] && continue
    local fn
    fn=$(basename "$f")
    local f_rank f_ts
    f_rank=$(printf '%s' "$fn" | cut -d- -f1)
    f_ts=$(printf '%s' "$fn" | cut -d- -f2)
    # Other entry must be lower-priority (higher rank number) AND older timestamp.
    if [ "$f_rank" -gt "$our_rank" ] 2>/dev/null && [ "$f_ts" -lt "$our_ts" ] 2>/dev/null; then
      skipped=$((skipped + 1))
      local f_task
      f_task=$(_bq_entry_field id "$f")
      [ -z "$f_task" ] && f_task=unknown
      if [ -z "$skipped_tasks" ]; then
        skipped_tasks="\"$(_bq_json_escape "$f_task")\""
      else
        skipped_tasks="$skipped_tasks,\"$(_bq_json_escape "$f_task")\""
      fi
    fi
  done < <(find "$qdir" -maxdepth 1 -type f -name '*.json' 2>/dev/null)

  [ "$skipped" -gt 0 ] || return 0

  local data
  data=$(printf '{"node":"%s","promoted_task":"%s","promoted_priority":"%s","skipped_count":%s,"skipped_tasks":[%s],"waited_s":%s}' \
    "$node" "$task" "$our_pri" "$skipped" "$skipped_tasks" "$waited")
  emit_event_keyed achilles task build_queue_promoted "$task" "$data" >/dev/null 2>&1 || true
}

bq_acquire_slot_lock() {
  local lock_base="${1:?bq_acquire_slot_lock: lock_base required}"
  local slots="${2:-1}" timeout_s="${3:-1800}"
  local lock="" wait_s=0 backoff=10 candidate s
  mkdir -p "$lock_base" 2>/dev/null || {
    printf 'bq_acquire_slot_lock: mkdir %s failed\n' "$lock_base" >&2
    return 2
  }
  case "$slots" in ''|*[!0-9]*) slots=1 ;; esac
  [ "$slots" -lt 1 ] && slots=1

  while [ -z "$lock" ]; do
    for s in $(seq 1 "$slots"); do
      candidate="$lock_base/slot-$s"
      if mkdir "$candidate" 2>/dev/null; then
        lock="$candidate"
        printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
        break
      fi
      if [ -n "$(find "$candidate" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
        printf 'warn: stale xcodebuild lock (>45m, slot %s), reclaiming\n' "$s" >&2
        rm -rf "$candidate"
        if mkdir "$candidate" 2>/dev/null; then
          lock="$candidate"
          printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
          break
        fi
      fi
    done
    [ -n "$lock" ] && break
    if [ "$wait_s" -ge "$timeout_s" ]; then
      printf 'bq_acquire_slot_lock: wait exceeded %ss (slots=%s)\n' "$timeout_s" "$slots" >&2
      return 3
    fi
    sleep "$backoff"
    wait_s=$((wait_s + backoff))
  done

  printf '%s\n' "$lock"
}

bq_release_slot_lock() {
  rm -rf "${1:-}" 2>/dev/null || true
}

# bq_release <entry_path> — remove queue entry (idempotent, safe to call in trap).
bq_release() {
  rm -f "${1:-}" 2>/dev/null || true
}
