#!/usr/bin/env bash
# dispatch-review.sh — host-agnostic Argus dispatch (replaces Claude-Code-only
# Agent-tool spawn in Achilles Step 8.5).
#
# Contract:
#   scripts/dispatch-review.sh <task-id> <stage> --idempotency-key <key> \
#       [--task-uuid <uuid>] [--attempt <n>]
#
#   <stage> ∈ spec | quality
#
# Behaviour (numbered to match #122):
#   1. Dedup-scan today's event log for a prior review_{approved|flagged|blocked}
#      tagged with the same idempotency_key. Found → emit `action_deduped`,
#      print the prior verdict, exit 0. Not found → continue.
#   2. Resolve $STUDIO_HOST (default claude-code) → load capabilities.yaml.
#   3. Argus security floor: secret_scope must be `none` (reference host
#      claude-code is exempt; documented in hosts/ADAPTER-SPEC.md). Refuse
#      with a loud error if the floor is unmet.
#   4. Build a handoff envelope and validate against handoff.schema.json via
#      validate-contract.sh. Validator rejection NEVER auto-retries (per
#      _shared/contracts/idempotency.md §Per-step retry classification).
#   5. Spawn the host's review primitive with env-scrub: env -i passes only
#      PATH/HOME/LANG/USER, the host plugin-root, and the explicit task/stage
#      context. NO ANTHROPIC_API_KEY, NO GH_TOKEN/GITHUB_TOKEN, NO inherited
#      arbitrary env. The host CLI re-authenticates from its own keychain.
#   6. Block by tailing the event log for a review_* event whose envelope
#      carries the same idempotency_key. Timeout: $DISPATCH_REVIEW_TIMEOUT
#      seconds (default 600). Per capabilities.block_for_event_strategy=tail.
#   7. Print `ARGUS_VERDICT=<approved|flagged|blocked>` on stdout. Exit 0
#      on verdict, non-zero on unrecoverable error.
#
# Retry policy: callers may retry once at the dispatch layer for transient
# failures (timeout, spawn fork failure). The script itself does NOT auto-
# retry — single retry layer per REVIEW.md R15.

set -u
umask 022

usage() {
  printf 'usage: dispatch-review.sh <task-id> <stage> --idempotency-key <key> [--task-uuid <uuid>] [--attempt <n>]\n' >&2
  exit 2
}

[ $# -ge 2 ] || usage
TASK_ID="$1"
STAGE="$2"
shift 2

case "$STAGE" in
  spec|quality) ;;
  *) printf 'dispatch-review: stage must be spec|quality (got: %s)\n' "$STAGE" >&2; exit 2 ;;
esac

IDEM_KEY=""
TASK_UUID=""
ATTEMPT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --idempotency-key) IDEM_KEY="${2:?}"; shift 2 ;;
    --task-uuid)       TASK_UUID="${2:?}"; shift 2 ;;
    --attempt)         ATTEMPT="${2:?}"; shift 2 ;;
    *) printf 'dispatch-review: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done
[ -n "$IDEM_KEY" ] || { printf 'dispatch-review: --idempotency-key is required\n' >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TIMEOUT="${DISPATCH_REVIEW_TIMEOUT:-600}"
WORKTREE="${ACHILLES_WORKTREE:-}"
BASE_BRANCH="${ACHILLES_BASE_BRANCH:-}"
SIZE="${TASK_SIZE:-}"

event_log=$(resolve_event_log) || {
  printf 'dispatch-review: cannot resolve event log path\n' >&2
  exit 1
}

# Trap-based "every exit emits a verdict-or-skip event" guard. Without it, any
# non-zero exit between Step 1 and Step 7 leaves the task with no Argus-side
# event, which is exactly the silent-skip shape #154 describes. SKIP_REASON is
# set on each early-exit path before `exit 1`; success path zeroes it.
DISPATCH_TERMINAL_EMITTED=0
SKIP_REASON=""
_emit_skip_if_open() {
  [ "$DISPATCH_TERMINAL_EMITTED" = "1" ] && return 0
  local rc=$?
  local reason="${SKIP_REASON:-unknown_exit_$rc}"
  emit_event_keyed argus review argus_gate_skipped "$TASK_ID" \
    "{\"stage\":\"$STAGE\",\"idem_key\":\"$IDEM_KEY\",\"reason\":\"$reason\",\"exit_code\":$rc}" \
    --idem-key "$IDEM_KEY" >/dev/null 2>&1 || true
}
trap _emit_skip_if_open EXIT INT TERM

# ---- Step 1: dedup ----------------------------------------------------------
# Two senders can race on the same key — the contract says producer-side dedupe
# pre-write. dispatch-review is the producer of `review_*` events on the
# spawning side; we scan for a prior verdict matching this key, regardless of
# which session emitted it. JSON keys are stable in lib-ledger output, so a
# substring match on the escaped `idempotency_key` JSON field is sufficient.
verdict_from_event() {
  printf '%s' "$1" | python3 -c '
import sys, json
try:
    e = json.loads(sys.stdin.read())
    ev = e.get("event") or e.get("kind") or ""
    if ev.startswith("review_"):
        print(ev.split("_", 1)[1])
except Exception:
    pass
'
}
find_prior_verdict() {
  [ -f "$event_log" ] || return 1
  grep -F "\"idempotency_key\":\"$IDEM_KEY\"" "$event_log" 2>/dev/null \
    | grep -E '"event":"review_(approved|flagged|blocked)"' \
    | tail -1
}
prior=$(find_prior_verdict || true)
if [ -n "$prior" ]; then
  v=$(verdict_from_event "$prior")
  if [ -n "$v" ]; then
    emit_event_keyed argus review action_deduped "$TASK_ID" \
      "{\"idem_key\":\"$IDEM_KEY\",\"stage\":\"$STAGE\",\"verdict\":\"$v\"}" \
      --idem-key "$IDEM_KEY" >/dev/null 2>&1 || true
    printf 'ARGUS_VERDICT=%s\n' "$v"
    DISPATCH_TERMINAL_EMITTED=1
    exit 0
  fi
fi

# ---- Step 2: resolve STUDIO_HOST + capability manifest ----------------------
HOST="${STUDIO_HOST:-claude-code}"
case "$HOST" in
  claude-code) host_dir="$REPO_ROOT/.claude-plugin" ;;
  codex)       host_dir="$REPO_ROOT/.codex" ;;
  *) SKIP_REASON="unknown_host"; printf 'dispatch-review: unknown STUDIO_HOST=%s (no adapter)\n' "$HOST" >&2; exit 1 ;;
esac
manifest="$host_dir/capabilities.yaml"
[ -f "$manifest" ] || { SKIP_REASON="missing_manifest"; printf 'dispatch-review: missing %s\n' "$manifest" >&2; exit 1; }

yaml_field() {
  grep -E "^${2}:[[:space:]]" "$1" 2>/dev/null \
    | head -1 \
    | sed "s/^${2}:[[:space:]]*//" \
    | tr -d '"'"'"
}
SPAWN_COMMAND=$(yaml_field "$manifest" spawn_command)
SECRET_SCOPE=$(yaml_field "$manifest" secret_scope)
[ -n "$SPAWN_COMMAND" ] || { SKIP_REASON="missing_spawn_command"; printf 'dispatch-review: %s missing spawn_command\n' "$manifest" >&2; exit 1; }

# ---- Step 3: Argus security floor ------------------------------------------
# Reference host (claude-code) is documented-exempt (see hosts/ADAPTER-SPEC.md).
# Any other host MUST declare secret_scope: none for Argus dispatch. Refuse
# loudly otherwise — Argus consumes diffs and emits verdicts; injecting
# secrets into its session is unnecessary surface for a future prompt-
# injection in a diff to exfiltrate.
if [ "$HOST" != "claude-code" ] && [ "$SECRET_SCOPE" != "none" ]; then
  SKIP_REASON="secret_scope_floor_unmet"
  printf 'dispatch-review: refuse — host=%s declares secret_scope=%s; Argus dispatch requires secret_scope: none. Add a dedicated Argus adapter (see hosts/ADAPTER-SPEC.md §Argus security floor) or route Argus to a none-scoped host.\n' \
    "$HOST" "$SECRET_SCOPE" >&2
  exit 1
fi

# ---- Step 4: build + validate handoff payload ------------------------------
handoff_path=$(mktemp -t dispatch-review.XXXXXX) || { SKIP_REASON="mktemp_failed"; exit 1; }
handoff_path="${handoff_path}.json"
# Compose with _emit_skip_if_open — earlier-installed trap must keep firing.
trap '_emit_skip_if_open; rm -f "$handoff_path" "$handoff_path.tmp"' EXIT

task_id_field='null'
if [ -n "$TASK_UUID" ]; then
  task_id_field="\"$TASK_UUID\""
fi

cat > "$handoff_path" <<EOF
{
  "schema_version": 1,
  "from": "achilles",
  "to": "argus",
  "task_id": $task_id_field,
  "reason": "review:$STAGE for $TASK_ID (attempt $ATTEMPT)",
  "payload_ref": {
    "task_id": "$TASK_ID",
    "stage": "$STAGE",
    "worktree": "$WORKTREE",
    "base_branch": "$BASE_BRANCH",
    "size": "$SIZE"
  },
  "idempotency_key": "$IDEM_KEY"
}
EOF

validator_err=$(mktemp -t dispatch-review-validate.XXXXXX) || { SKIP_REASON="mktemp_failed"; exit 1; }
# Replace prior tmpfile-only trap, but keep _emit_skip_if_open running on EXIT.
trap '_emit_skip_if_open; rm -f "$handoff_path" "$handoff_path.tmp" "$validator_err"' EXIT
if ! "$SCRIPT_DIR/validate-contract.sh" handoff "$handoff_path" 2>"$validator_err"; then
  rc=$?
  if [ "$rc" -eq 2 ]; then
    SKIP_REASON="validator_unavailable"
    printf 'dispatch-review: validator unavailable (check-jsonschema not installed). Install per _shared/contracts/EVOLUTION.md.\n' >&2
  else
    SKIP_REASON="handoff_schema_violation"
    printf 'dispatch-review: handoff payload rejected (schema_violation, no auto-retry per _shared/contracts/idempotency.md §retry classification).\n' >&2
  fi
  cat "$validator_err" >&2 2>/dev/null || true
  exit 1
fi

# ---- Step 5: env-scrubbed spawn -------------------------------------------
# Mark the log cursor so Step 6 reads only post-spawn lines.
log_cursor=0
if [ -f "$event_log" ]; then
  log_cursor=$(wc -c < "$event_log" 2>/dev/null | tr -d ' ' || echo 0)
fi

# Word-split spawn_command into argv array (e.g. "claude -p" → claude + -p).
# shellcheck disable=SC2206
spawn_argv=( $SPAWN_COMMAND )
review_prompt="/argus $STAGE $TASK_ID"

env -i \
  PATH="$PATH" \
  HOME="$HOME" \
  LANG="${LANG:-C.UTF-8}" \
  USER="${USER:-}" \
  STUDIO_HOST="$HOST" \
  CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}" \
  CODEX_PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-}" \
  TASK_ID="$TASK_ID" \
  STAGE="$STAGE" \
  ARGUS_IDEMPOTENCY_KEY="$IDEM_KEY" \
  ACHILLES_WORKTREE="$WORKTREE" \
  ACHILLES_BASE_BRANCH="$BASE_BRANCH" \
  TASK_SIZE="$SIZE" \
  "${spawn_argv[@]}" "$review_prompt" >/dev/null 2>&1 &
spawn_pid=$!

# ---- Step 6: tail event log for verdict ------------------------------------
elapsed=0
verdict=""
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  if [ -f "$event_log" ]; then
    new_lines=$(tail -c "+$((log_cursor + 1))" "$event_log" 2>/dev/null || true)
    if [ -n "$new_lines" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
          *"\"idempotency_key\":\"$IDEM_KEY\""*)
            case "$line" in
              *'"event":"review_approved"'*) verdict="approved" ;;
              *'"event":"review_flagged"'*)  verdict="flagged" ;;
              *'"event":"review_blocked"'*)  verdict="blocked" ;;
            esac
            ;;
        esac
        [ -n "$verdict" ] && break
      done <<EOF
$new_lines
EOF
    fi
    [ -n "$verdict" ] && break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

# Reap spawn (best-effort; the spawn may have exited cleanly already).
wait "$spawn_pid" 2>/dev/null || true

if [ -z "$verdict" ]; then
  SKIP_REASON="verdict_timeout_${TIMEOUT}s"
  printf 'dispatch-review: timeout (%ds) waiting for review_* event with idempotency_key=%s\n' \
    "$TIMEOUT" "$IDEM_KEY" >&2
  exit 1
fi

# ---- Step 7: print verdict -------------------------------------------------
# Spawned argus already emitted review_<verdict> via argus-emit-verdict.sh;
# DISPATCH_TERMINAL_EMITTED suppresses the skip-emit on the success path.
DISPATCH_TERMINAL_EMITTED=1
printf 'ARGUS_VERDICT=%s\n' "$verdict"
exit 0
