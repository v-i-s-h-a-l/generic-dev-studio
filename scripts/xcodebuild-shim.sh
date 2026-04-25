#!/usr/bin/env bash
# xcodebuild-shim.sh — swap layer between Achilles/Argus and xcodebuild.
#
# Routes the inner build call to either:
#   * `xcodebuildmcp` CLI (getsentry/XcodeBuildMCP) when available + opted-in.
#     Structured JSON output is captured to a sidecar `<log>.json` so
#     downstream events can enrich `build_check_failed` payloads with
#     error-level detail. Stdout / stderr still mirror xcodebuild-style
#     text so the existing grep-based error/warning parsers keep working.
#   * `xcodebuild` direct (today's behavior) otherwise.
#
# Routing rules (highest precedence first):
#   1. STUDIO_XCODEBUILDMCP=0          → always use xcodebuild
#   2. STUDIO_XCODEBUILDMCP=1          → require xcodebuildmcp; fail if missing
#   3. STUDIO_XCODEBUILDMCP unset/auto → use xcodebuildmcp if on PATH; else
#                                        fall back to xcodebuild silently
#
# Usage:
#   scripts/xcodebuild-shim.sh build  -scheme ... -destination ... -derivedDataPath ... [...]
#   scripts/xcodebuild-shim.sh test   -scheme ... -destination ... -derivedDataPath ... [-resultBundlePath ...] [-only-testing:...] [...]
#
# Caller-facing contract:
#   - Same flags as xcodebuild for `build` and `test` actions.
#   - Same exit-code semantics: 0 on success, non-zero on failure.
#   - When xcodebuildmcp is in use AND a JSON sidecar can be derived, the
#     sidecar lands at the path named by $XCB_JSON_SIDECAR (env var the
#     caller sets); when unset, the sidecar is discarded.
#   - Stdout/stderr semantics match xcodebuild closely enough for the
#     existing `grep -cE '(^|: )error:'` parsers to keep working.
#
# This shim is intentionally thin — it is a routing primitive, not a build
# system. New build features go in the call sites; the shim only swaps
# implementations.

set -u
umask 022

ACTION="${1:-}"
[ -z "$ACTION" ] && { printf 'xcodebuild-shim: usage: %s <build|test> [args...]\n' "$0" >&2; exit 2; }
shift

# Decide the executor.
have_mcp=0
if command -v xcodebuildmcp >/dev/null 2>&1; then have_mcp=1; fi

mode="${STUDIO_XCODEBUILDMCP:-auto}"
case "$mode" in
  0|off|false|disabled) executor=xcodebuild ;;
  1|on|true|enabled)
    if [ "$have_mcp" -ne 1 ]; then
      printf 'xcodebuild-shim: STUDIO_XCODEBUILDMCP=1 set but xcodebuildmcp not on PATH; refusing to silently fall back\n' >&2
      exit 2
    fi
    executor=xcodebuildmcp ;;
  ""|auto)
    if [ "$have_mcp" -eq 1 ]; then executor=xcodebuildmcp; else executor=xcodebuild; fi ;;
  *)
    printf 'xcodebuild-shim: STUDIO_XCODEBUILDMCP=%s — expected 0|1|auto\n' "$mode" >&2; exit 2 ;;
esac

# xcodebuild path: trivial passthrough preserving today's behavior.
if [ "$executor" = "xcodebuild" ]; then
  exec xcodebuild "$ACTION" "$@"
fi

# xcodebuildmcp path. The CLI accepts the same flags by design (per
# getsentry/XcodeBuildMCP CLI mode documentation referenced in #173).
# Capture structured JSON when possible: the CLI writes JSON to stdout when
# `--json` (or equivalent) is passed; we direct it to the sidecar and emit
# a compact xcodebuild-like text stream on the original stdout/stderr so
# existing parsers keep working.
#
# When the CLI does not emit JSON (e.g. an older version), we fall through
# to direct invocation that matches xcodebuild's output shape.
sidecar="${XCB_JSON_SIDECAR:-}"
if [ -n "$sidecar" ]; then
  # Try the JSON path first; on any failure (older CLI without --json,
  # invocation error, schema drift), retry without the JSON flag and emit
  # nothing into the sidecar.
  tmpjson=$(mktemp -t xcb-shim.XXXXXX.json)
  if xcodebuildmcp "$ACTION" "$@" --json >"$tmpjson" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  # Persist sidecar iff content is non-empty + parses as JSON.
  if [ -s "$tmpjson" ] && command -v jq >/dev/null 2>&1 && jq -e . <"$tmpjson" >/dev/null 2>&1; then
    mv "$tmpjson" "$sidecar"
    # Project a text view of the JSON onto stdout for existing parsers.
    # Errors → "error: <message>"; warnings → "warning: <message>".
    jq -r '
      (.errors // [])   | .[] | "error: " + (.message // (. | tostring))
    ' "$sidecar" 2>/dev/null
    jq -r '
      (.warnings // []) | .[] | "warning: " + (.message // (. | tostring))
    ' "$sidecar" 2>/dev/null
  else
    # Not JSON — emit raw output (xcodebuild-compatible).
    cat "$tmpjson"
    rm -f "$tmpjson"
  fi
  exit "$rc"
fi

# No sidecar requested — straight passthrough to xcodebuildmcp.
exec xcodebuildmcp "$ACTION" "$@"
