#!/usr/bin/env bash
# lib-worktree-marker.sh — shared writer/reader for the per-worktree marker
# documented in _shared/contracts/worktree-marker.md.
#
# Sourced by ingest, plan-chain, work-chain, task-worktree-setup, and the
# gc/cleanup tools. Stays small and dependency-light: jq is preferred when
# present, but every reader has an awk fallback so the gc can still run on
# hosts without jq.
#
# Public functions:
#   worktree_marker_path <worktree-dir>
#   worktree_marker_write <worktree-dir> <kind> [--project <p>] \
#                                                [--session-id <s>] \
#                                                [--chain-id <c>] \
#                                                [--task-id <t>] \
#                                                [--host <h>] \
#                                                [--pid <pid>]
#   worktree_marker_touch <worktree-dir>
#   worktree_marker_read  <worktree-dir> <field>
#   worktree_marker_age_seconds <worktree-dir>
#
# All functions write to stderr on hard failure (missing arg, marker not
# JSON-parseable) and return non-zero. Best-effort reads (field absent) return
# 0 and print an empty string.

# No `set -e` — sourced into mixed-mode scripts.

_worktree_marker_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_worktree_marker_now_epoch() {
  date -u +%s
}

worktree_marker_path() {
  local wt="${1:?usage: worktree_marker_path <worktree-dir>}"
  printf '%s\n' "$wt/.studio-worktree.json"
}

# Parse an ISO-8601 UTC timestamp into epoch seconds. macOS and GNU date have
# divergent flag sets; this helper tries both shapes and falls back to a
# python3 one-shot when neither matches. Returns 0 + epoch on stdout when
# successful, returns 1 silently when not (caller decides whether absence is
# an error or a soft skip).
_worktree_marker_iso_to_epoch() {
  local iso="${1:-}"
  [ -n "$iso" ] || return 1
  local epoch
  if epoch=$(date -u -d "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$epoch"
    return 0
  fi
  if epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$epoch"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    epoch=$(python3 - "$iso" <<'PY' 2>/dev/null
import sys, datetime
iso = sys.argv[1]
try:
    dt = datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    sys.exit(1)
print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
PY
    ) && { printf '%s\n' "$epoch"; return 0; }
  fi
  return 1
}

# Read a string field from a marker file. jq when present; small awk reader
# otherwise. Always exits 0 — absent fields produce empty output so callers
# can use `if [ -z "$x" ]` without juggling non-zero exits on best-effort
# reads.
_worktree_marker_field() {
  local file="${1:-}" field="${2:-}"
  [ -f "$file" ] || { printf ''; return 0; }
  [ -n "$field" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null
    return 0
  fi
  awk -v field="\"$field\"" '
    BEGIN { found = 0 }
    {
      line = $0
      idx = index(line, field)
      if (idx > 0) {
        rest = substr(line, idx + length(field))
        colon = index(rest, ":")
        if (colon == 0) next
        val = substr(rest, colon + 1)
        gsub(/^[ \t]+/, "", val)
        gsub(/,[ \t]*$/, "", val)
        gsub(/[ \t]+$/, "", val)
        if (substr(val, 1, 1) == "\"") {
          val = substr(val, 2)
          q = index(val, "\"")
          if (q > 0) val = substr(val, 1, q - 1)
        }
        if (val == "null") val = ""
        print val
        found = 1
        exit
      }
    }
    END { if (!found) print "" }
  ' "$file" 2>/dev/null
  return 0
}

# Emit a minimal JSON marker. Hand-rolled to avoid a jq dependency on the
# write path (gc-only hosts can still source this library). Values are
# minimally escaped — only `"` and `\` — which is sufficient for the closed
# value space (slugs, ISO timestamps, ids, integers).
_worktree_marker_emit_json() {
  local kind="$1" slug="$2" project="$3" created_at="$4" last_touched="$5"
  local session_id="$6" chain_id="$7" task_id="$8" host="$9" pid="${10}"
  _w_esc() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
  }
  _w_field_str() {
    local key="$1" val="$2"
    if [ -z "$val" ]; then
      printf '  "%s": null' "$key"
    else
      printf '  "%s": "%s"' "$key" "$(_w_esc "$val")"
    fi
  }
  _w_field_int() {
    local key="$1" val="$2"
    if [ -z "$val" ]; then
      printf '  "%s": null' "$key"
    else
      printf '  "%s": %d' "$key" "$val"
    fi
  }
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    _w_field_str kind "$kind"; printf ',\n'
    _w_field_str slug "$slug"; printf ',\n'
    _w_field_str project "$project"; printf ',\n'
    _w_field_str created_at "$created_at"; printf ',\n'
    _w_field_str last_touched "$last_touched"; printf ',\n'
    _w_field_str session_id "$session_id"; printf ',\n'
    _w_field_str chain_id "$chain_id"; printf ',\n'
    _w_field_str task_id "$task_id"; printf ',\n'
    _w_field_str host "$host"; printf ',\n'
    _w_field_int pid "$pid"; printf '\n'
    printf '}\n'
  }
}

worktree_marker_write() {
  local wt="${1:?usage: worktree_marker_write <worktree-dir> <kind> [opts]}"
  local kind="${2:?kind required (ingest|plan|chain|worker)}"
  shift 2 || true

  local project="" session_id="" chain_id="" task_id="" host="" pid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)    project="${2:-}"; shift 2 ;;
      --session-id) session_id="${2:-}"; shift 2 ;;
      --chain-id)   chain_id="${2:-}"; shift 2 ;;
      --task-id)    task_id="${2:-}"; shift 2 ;;
      --host)       host="${2:-}"; shift 2 ;;
      --pid)        pid="${2:-}"; shift 2 ;;
      *) printf 'worktree_marker_write: unknown flag %s\n' "$1" >&2; return 2 ;;
    esac
  done

  case "$kind" in
    ingest|plan|chain|worker) ;;
    *)
      printf 'worktree_marker_write: kind must be one of ingest|plan|chain|worker (got %s)\n' "$kind" >&2
      return 2
      ;;
  esac
  if [ ! -d "$wt" ]; then
    printf 'worktree_marker_write: worktree dir %s does not exist\n' "$wt" >&2
    return 2
  fi

  local slug
  slug=$(basename "$wt")
  if [ -z "$project" ]; then
    # parent of <slug> is the worktrees/ dir; its parent is the project root.
    project=$(basename "$(dirname "$wt")")
    if [ "$project" = "worktrees" ]; then
      project=$(basename "$(dirname "$(dirname "$wt")")")
    fi
  fi

  local marker
  marker=$(worktree_marker_path "$wt")
  local now
  now=$(_worktree_marker_now_iso)
  local created_at="$now"
  if [ -f "$marker" ]; then
    local existing
    existing=$(_worktree_marker_field "$marker" created_at)
    [ -n "$existing" ] && created_at="$existing"
  fi

  local tmp
  tmp="$marker.tmp.$$"
  if ! _worktree_marker_emit_json \
        "$kind" "$slug" "$project" "$created_at" "$now" \
        "$session_id" "$chain_id" "$task_id" "$host" "$pid" \
        > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$marker"
}

worktree_marker_touch() {
  local wt="${1:?usage: worktree_marker_touch <worktree-dir>}"
  local marker
  marker=$(worktree_marker_path "$wt")
  if [ ! -f "$marker" ]; then
    printf 'worktree_marker_touch: marker missing at %s (worktree not initialized)\n' "$marker" >&2
    return 1
  fi
  local kind slug project created_at session_id chain_id task_id host pid
  kind=$(_worktree_marker_field "$marker" kind)
  slug=$(_worktree_marker_field "$marker" slug)
  project=$(_worktree_marker_field "$marker" project)
  created_at=$(_worktree_marker_field "$marker" created_at)
  session_id=$(_worktree_marker_field "$marker" session_id)
  chain_id=$(_worktree_marker_field "$marker" chain_id)
  task_id=$(_worktree_marker_field "$marker" task_id)
  host=$(_worktree_marker_field "$marker" host)
  pid=$(_worktree_marker_field "$marker" pid)

  # Guard against a partially-written marker (missing required fields).
  if [ -z "$kind" ] || [ -z "$slug" ] || [ -z "$project" ] || [ -z "$created_at" ]; then
    printf 'worktree_marker_touch: marker at %s missing required fields\n' "$marker" >&2
    return 1
  fi

  local now
  now=$(_worktree_marker_now_iso)
  local tmp="$marker.tmp.$$"
  _worktree_marker_emit_json \
    "$kind" "$slug" "$project" "$created_at" "$now" \
    "$session_id" "$chain_id" "$task_id" "$host" "$pid" \
    > "$tmp"
  mv "$tmp" "$marker"
}

worktree_marker_read() {
  local wt="${1:?usage: worktree_marker_read <worktree-dir> <field>}"
  local field="${2:?field required}"
  local marker
  marker=$(worktree_marker_path "$wt")
  _worktree_marker_field "$marker" "$field"
}

worktree_marker_age_seconds() {
  local wt="${1:?usage: worktree_marker_age_seconds <worktree-dir>}"
  local marker
  marker=$(worktree_marker_path "$wt")
  if [ ! -f "$marker" ]; then
    printf 'worktree_marker_age_seconds: no marker at %s\n' "$marker" >&2
    return 1
  fi
  local last_touched epoch now
  last_touched=$(_worktree_marker_field "$marker" last_touched)
  if [ -z "$last_touched" ]; then
    printf 'worktree_marker_age_seconds: last_touched missing in %s\n' "$marker" >&2
    return 1
  fi
  if ! epoch=$(_worktree_marker_iso_to_epoch "$last_touched"); then
    printf 'worktree_marker_age_seconds: cannot parse last_touched=%s in %s\n' "$last_touched" "$marker" >&2
    return 1
  fi
  now=$(_worktree_marker_now_epoch)
  printf '%d\n' "$((now - epoch))"
}
