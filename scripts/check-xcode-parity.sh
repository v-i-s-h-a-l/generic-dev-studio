#!/usr/bin/env bash
# check-xcode-parity.sh — pre-flight guard for remote-dispatch builds (#136).
#
# Compares the laptop's Xcode version against a target node's, reading from
# the cache produced by scripts/node-parity.sh. Exit code is the routing
# verdict that callers in task-build-gate.sh / task-test-gate.sh consume
# before any lock or SSH cost is paid.
#
# Drift policy (user-set 2026-04-27, "for now" — see memory):
#   - MAJOR differs (e.g. 26.x ↔ 25.x) → BLOCK (exit 1) unless override.
#   - MINOR differs (e.g. 26.3 ↔ 26.4) → WARN, allow.
#   - PATCH differs (e.g. 26.4.0 ↔ 26.4.1) → WARN, allow.
#   - Identical or self-target → silent allow.
# Override: STUDIO_IGNORE_XCODE_DRIFT=1 demotes all drift to warn-only.
#
# Cache freshness: 7 days. Stale or missing → silently invoke node-parity.sh
# to refresh (one cheap SSH per registered node). Refresh failure under a
# stale cache is treated as warn-and-proceed; refusing to dispatch when the
# probe fails would paper-cut routine offline windows.
#
# Usage:
#   scripts/check-xcode-parity.sh <target-node-id>
#
# Exit codes:
#   0   allow dispatch (silent OK or warn-and-allow on minor/patch drift)
#   1   block dispatch (major drift without override)
#   2   bad args / unrecoverable cache state (no laptop entry, no target entry)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TARGET_ID="${1:?usage: check-xcode-parity.sh <target-node-id>}"

# Self-target → no possible drift; short-circuit before reading anything.
if node_is_self "$TARGET_ID"; then
  exit 0
fi

CACHE="$(resolve_runtime_global)/node-parity-cache.json"
CACHE_TTL_S=$((7 * 24 * 3600))

command -v jq >/dev/null 2>&1 || {
  printf 'check-xcode-parity: jq required\n' >&2
  exit 2
}

# Refresh the cache when missing or older than the TTL. The probe is best-
# effort: if it fails (mini offline mid-run, transient SSH error), we keep
# whatever cached snapshot exists. A stale-but-present cache is more useful
# than blocking dispatch on a refresh hiccup.
needs_refresh=0
if [ ! -r "$CACHE" ]; then
  needs_refresh=1
else
  generated_at=$(jq -r '.generated_at // ""' "$CACHE" 2>/dev/null)
  if [ -z "$generated_at" ]; then
    needs_refresh=1
  else
    # `date -j -f` is BSD; `date -d` is GNU. Try both, fall back to "stale"
    # when neither parses the ISO-8601 stamp.
    cache_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$generated_at" +%s 2>/dev/null) \
      || cache_epoch=$(date -u -d "$generated_at" +%s 2>/dev/null) \
      || cache_epoch=0
    now_epoch=$(date -u +%s)
    if [ "$cache_epoch" = "0" ] || [ "$((now_epoch - cache_epoch))" -gt "$CACHE_TTL_S" ]; then
      needs_refresh=1
    fi
  fi
fi

if [ "$needs_refresh" = "1" ]; then
  printf 'check-xcode-parity: refreshing node-parity cache (stale or missing)…\n' >&2
  "$SCRIPT_DIR/node-parity.sh" >/dev/null 2>&1 || true
fi

if [ ! -r "$CACHE" ]; then
  # Refresh failed AND no prior cache. Without any data we can't compare —
  # warn loudly and allow dispatch; the alternative (block) would paper-cut
  # any first-time offload before parity has ever been probed.
  printf 'warn: check-xcode-parity: no parity cache and refresh failed — proceeding without drift check\n' >&2
  exit 0
fi

# Resolve self id by walking the registry for the entry whose machine_id
# matches this machine. Falls back to "laptop" when the machine isn't
# registered (legacy single-node setups).
SELF_ID=$(jq -r --arg mid "$(resolve_self_machine_id 2>/dev/null)" \
  '.nodes[]? | select(.machine_id == $mid) | .id // empty' \
  "$(resolve_runtime_global)/nodes.json" 2>/dev/null \
  | head -1)
[ -z "$SELF_ID" ] && SELF_ID=laptop

self_ver=$(jq -r --arg id "$SELF_ID" '.nodes[$id].xcodebuild.version // ""' "$CACHE" 2>/dev/null)
target_ver=$(jq -r --arg id "$TARGET_ID" '.nodes[$id].xcodebuild.version // ""' "$CACHE" 2>/dev/null)
target_reach=$(jq -r --arg id "$TARGET_ID" '.nodes[$id].reachable // false' "$CACHE" 2>/dev/null)

if [ -z "$self_ver" ] || [ -z "$target_ver" ]; then
  # Either side missing from cache → can't compute. Warn-and-allow rather
  # than block: callers that wanted strict guardrails would set
  # STUDIO_IGNORE_XCODE_DRIFT=0 explicitly, and even then a missing cache
  # entry isn't drift, it's "unknown."
  printf 'warn: check-xcode-parity: cache missing xcodebuild for self=%s or target=%s — proceeding\n' "$SELF_ID" "$TARGET_ID" >&2
  exit 0
fi

if [ "$target_reach" != "true" ]; then
  printf 'warn: check-xcode-parity: target %s last probed unreachable — proceeding (cached drift only)\n' "$TARGET_ID" >&2
fi

# Parse "26.4.1" → major=26 minor=4 patch=1; missing components default to 0.
# Awk handles non-numeric trailing chars (e.g. "15.4-beta") by truncating
# at the first non-digit per component; the field-set on iOS Xcode releases
# never carries letters in MAJOR.MINOR.PATCH so this is conservative.
parse_semver() {
  printf '%s' "$1" | awk -F. '
    BEGIN { OFS=" " }
    { for (i=1; i<=3; i++) { v=$i+0; printf "%d ", v } }
  '
}
read -r self_major  self_minor  self_patch  <<<"$(parse_semver "$self_ver")"
read -r target_major target_minor target_patch <<<"$(parse_semver "$target_ver")"

if [ "$self_major" = "$target_major" ] && [ "$self_minor" = "$target_minor" ] && [ "$self_patch" = "$target_patch" ]; then
  exit 0
fi

if [ "$self_major" != "$target_major" ]; then
  if [ "${STUDIO_IGNORE_XCODE_DRIFT:-0}" = "1" ]; then
    printf 'warn: check-xcode-parity: MAJOR Xcode drift %s (self=%s) vs %s (target=%s) — STUDIO_IGNORE_XCODE_DRIFT=1, proceeding\n' \
      "$self_ver" "$SELF_ID" "$target_ver" "$TARGET_ID" >&2
    exit 0
  fi
  cat >&2 <<EOF
check-xcode-parity: BLOCK — MAJOR Xcode drift between $SELF_ID ($self_ver) and $TARGET_ID ($target_ver).
  Different major Xcode = different SDK = different binaries. Builds dispatched
  to $TARGET_ID would diverge silently from a laptop build.
  Fix:
    1) Update Xcode on the lagging side, then re-run scripts/node-parity.sh.
    2) Or set STUDIO_IGNORE_XCODE_DRIFT=1 to override (deliberate cases only).
EOF
  exit 1
fi

# Minor or patch drift — warn but allow. Format the drift line so analysis
# greps can pull it cleanly: `xcode_drift=<self>->target<tgt>`.
printf 'warn: check-xcode-parity: minor/patch Xcode drift %s (self=%s) vs %s (target=%s) — proceeding\n' \
  "$self_ver" "$SELF_ID" "$target_ver" "$TARGET_ID" >&2
exit 0
