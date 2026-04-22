#!/usr/bin/env bash
# status-load-snapshots.sh — 4-domain snapshot freshness loop for /chanakya status.
#
# Reads briefs / debt / feedback-inbox / events-tail snapshots, classifies each
# as hit / stale / miss, emits snapshot_* events, fires background rewarms for
# stale/missing domains, and prints a consolidated JSON blob so the caller
# mode-pack has a single source of truth without loading each snapshot itself.
#
# Output (stdout, one JSON object):
#   {
#     "briefs":         {"state": "hit|stale|miss", "age_s": <n>, "payload": <json|null>},
#     "debt":           { ... },
#     "feedback-inbox": { ... },
#     "events-tail":    { ... }
#   }
#
# Stale + miss domains trigger `scripts/chanakya-snap.sh <domain> &` detached.
# Freshness window is fixed at 60s per _shared/patterns/router-pattern.md.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

FRESHNESS_S=60
DOMAINS="briefs debt feedback-inbox events-tail"

PROJECT=$(resolve_project 2>/dev/null) || { printf '{}' ; exit 2; }
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
SNAP_DIR="$PROJECT_ROOT/.runtime/state/chanakya-snapshots"

now_s=$(date -u +%s)

# Classify one snapshot file. Prints `state age_s` on stdout.
# state ∈ {hit, stale, miss-not_generated, miss-missing_file, miss-corrupt}.
classify_snapshot() {
  local path="$1"
  if [ ! -f "$path" ]; then
    printf 'miss-missing_file 0\n'
    return 0
  fi
  if [ ! -s "$path" ]; then
    printf 'miss-corrupt 0\n'
    return 0
  fi
  local gen_at
  gen_at=$(jq -r '.generated_at // empty' "$path" 2>/dev/null) || {
    printf 'miss-corrupt 0\n'
    return 0
  }
  if [ -z "$gen_at" ] || [ "$gen_at" = "null" ]; then
    printf 'miss-not_generated 0\n'
    return 0
  fi
  local gen_s
  gen_s=$(ts_to_epoch "$gen_at") || {
    printf 'miss-corrupt 0\n'
    return 0
  }
  local age=$(( now_s - gen_s ))
  if [ "$age" -le "$FRESHNESS_S" ]; then
    printf 'hit %s\n' "$age"
  else
    printf 'stale %s\n' "$age"
  fi
}

# Build one domain's JSON object: {"state":"...","age_s":N,"payload":<json|null>}.
# Emits the matching snapshot_* event as a side effect.
# Returns the domain JSON on stdout.
build_domain_json() {
  local domain="$1" path="$SNAP_DIR/$domain.json"
  local classification age payload event data

  read -r classification age < <(classify_snapshot "$path")

  case "$classification" in
    hit)
      payload=$(cat "$path")
      event=snapshot_hit
      data=$(printf '{"domain":"%s","age_seconds":%s}' "$domain" "$age")
      ;;
    stale)
      payload=null
      event=snapshot_stale
      data=$(printf '{"domain":"%s","age_seconds":%s,"staleness_window_seconds":%s}' \
        "$domain" "$age" "$FRESHNESS_S")
      ;;
    miss-*)
      payload=null
      event=snapshot_miss
      local reason="${classification#miss-}"
      data=$(printf '{"domain":"%s","reason":"%s"}' "$domain" "$reason")
      ;;
  esac

  append_event chanakya "$event" "" "$data" 2>/dev/null || true

  local state="${classification%%-*}"
  [ "$state" = "miss" ] && state=miss

  jq -nc \
    --arg state "$state" \
    --argjson age "${age:-0}" \
    --argjson payload "$payload" \
    '{state: $state, age_s: $age, payload: $payload}'
}

# Main loop — build each domain, concatenate into one top-level object.
out="{"
first=1
for domain in $DOMAINS; do
  if [ "$first" -eq 1 ]; then first=0; else out="${out},"; fi
  obj=$(build_domain_json "$domain")
  out="${out}\"${domain}\":${obj}"
done
out="${out}}"
printf '%s\n' "$out"

# Fire detached rewarms for any domain that wasn't a hit. Single-domain per fire
# keeps the background cost proportional to what actually fell behind.
for domain in $DOMAINS; do
  path="$SNAP_DIR/$domain.json"
  read -r classification _ < <(classify_snapshot "$path")
  case "$classification" in
    hit) : ;;
    *) ( "$SCRIPT_DIR/chanakya-snap.sh" "$domain" >/dev/null 2>&1 & ) ;;
  esac
done

exit 0
