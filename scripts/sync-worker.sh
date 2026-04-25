#!/usr/bin/env bash
# sync-worker.sh — apply the per-project worker manifest to one registered
# worker over SSH.
#
# Reads the manifest at ~/.dev-studio/<project>/worker-manifest.yaml,
# probes the named worker via existing dispatch primitives, and applies
# anything missing (brew packages mostly). Compares Xcode versions +
# simulator runtimes; surfaces drift loudly. Idempotent — safe to re-run.
#
# Workers are PASSIVE in this design — the manager pushes; workers don't
# pull. That keeps workers as dumb SSH targets per the architecture.
#
# Usage
#   scripts/sync-worker.sh <worker-id>           # apply
#   scripts/sync-worker.sh <worker-id> --dry-run # report only, change nothing
#
# Exit codes
#   0  worker is in-sync (or was, after applying)
#   1  unreachable / disabled / unknown worker
#   2  manifest missing / parse error / bad args
#   3  applied changes but some required item couldn't be installed
#
# Events emitted (per #137 / R14):
#   worker_sync_started          {studio.dispatch.node, studio.dispatch.role: "sync"}
#   worker_sync_drift_detected   {studio.dispatch.node, studio.sync.drift: [...]}
#   worker_sync_completed        {studio.dispatch.node, studio.sync.applied_count}
#   worker_sync_failed           {studio.dispatch.node, studio.sync.reason}

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true   # event helpers; optional fallback

WORKER_ID="${1:?usage: sync-worker.sh <worker-id> [--dry-run]}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

REGISTRY="$(resolve_runtime_global)/nodes.json"
PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
MANIFEST="$(resolve_project_root_for "$PROJECT")/worker-manifest.yaml"

# ---------- preflight ----------
if [ ! -r "$REGISTRY" ]; then
  printf 'error: node registry missing at %s\n' "$REGISTRY" >&2
  exit 1
fi
if [ ! -r "$MANIFEST" ]; then
  printf 'error: manifest missing at %s\n' "$MANIFEST" >&2
  printf 'hint: scripts/init-worker-manifest.sh creates a default one\n' >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf 'error: yq required (for manifest parsing)\n' >&2; exit 2; }

# Look up the worker entry. enable=false → skip; not found → exit 1.
ENTRY=$(jq -c -e --arg id "$WORKER_ID" '.nodes[]? | select(.id == $id)' "$REGISTRY" 2>/dev/null) || {
  printf 'error: worker %s not in nodes.json\n' "$WORKER_ID" >&2
  exit 1
}
ENABLED=$(printf '%s' "$ENTRY" | jq -r 'if .enabled == false then "false" else "true" end')
if [ "$ENABLED" != "true" ]; then
  printf 'sync-worker: %s is disabled in nodes.json — skipping\n' "$WORKER_ID" >&2
  exit 1
fi
HOST=$(printf '%s' "$ENTRY" | jq -r '.host // empty')
SSH_USER=$(printf '%s' "$ENTRY" | jq -r '.user // empty')
[ -z "$HOST" ] || [ -z "$SSH_USER" ] && {
  printf 'error: worker %s missing host/user\n' "$WORKER_ID" >&2; exit 1
}

# ---------- helpers ----------
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 30"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 30"

ssh_exec() { $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$@"; }

# Reachability bound up-front. Don't pretend we synced if we can't even talk.
if ! $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" true >/dev/null 2>&1; then
  printf 'error: worker %s (%s) unreachable\n' "$WORKER_ID" "$HOST" >&2
  emit_event_keyed sync worker worker_sync_failed "$WORKER_ID" \
    "{\"studio.dispatch.node\":\"$WORKER_ID\",\"studio.sync.reason\":\"unreachable\"}" \
    >/dev/null 2>&1 || true
  exit 1
fi

# ---------- read manifest ----------
REQUIRED_BREW=$(yq -r '.brew_packages.required[]?' "$MANIFEST" 2>/dev/null)
OPTIONAL_BREW=$(yq -r '.brew_packages.optional[]?' "$MANIFEST" 2>/dev/null)
XCODE_MIN=$(yq -r '.xcode_version_min // ""' "$MANIFEST" 2>/dev/null)

emit_event_keyed sync worker worker_sync_started "$WORKER_ID" \
  "{\"studio.dispatch.node\":\"$WORKER_ID\",\"studio.dispatch.role\":\"sync\",\"studio.sync.dry_run\":$([ "$DRY_RUN" = "1" ] && echo true || echo false)}" \
  >/dev/null 2>&1 || true

# ---------- brew presence check + install ----------
applied=0
drift=()

# Fetch the worker's brew package list once — single SSH round trip — and
# diff locally rather than hammering the worker per-package.
remote_brew=$(ssh_exec 'brew list --formula 2>/dev/null' || true)
if [ -z "$remote_brew" ]; then
  drift+=("brew_unavailable: brew not installed or empty list on $WORKER_ID")
fi

want_install=()
for pkg in $REQUIRED_BREW; do
  if ! printf '%s\n' "$remote_brew" | grep -qx "$pkg"; then
    want_install+=("$pkg")
    drift+=("missing_brew_required: $pkg")
  fi
done
optional_missing=()
for pkg in $OPTIONAL_BREW; do
  if ! printf '%s\n' "$remote_brew" | grep -qx "$pkg"; then
    optional_missing+=("$pkg")
    drift+=("missing_brew_optional: $pkg")
  fi
done

if [ "${#want_install[@]}" -gt 0 ] && [ "$DRY_RUN" = "0" ]; then
  printf 'sync-worker: installing %d missing required package(s) on %s: %s\n' \
    "${#want_install[@]}" "$WORKER_ID" "${want_install[*]}"
  if ssh_exec "brew install ${want_install[*]}"; then
    applied=$((applied + ${#want_install[@]}))
  else
    printf 'error: brew install failed on %s — required deps not satisfied\n' "$WORKER_ID" >&2
    emit_event_keyed sync worker worker_sync_failed "$WORKER_ID" \
      "{\"studio.dispatch.node\":\"$WORKER_ID\",\"studio.sync.reason\":\"brew_install_failed\"}" \
      >/dev/null 2>&1 || true
    exit 3
  fi
fi

# ---------- Xcode version drift (informational; not auto-fixed) ----------
if [ -n "$XCODE_MIN" ]; then
  remote_xcode=$(ssh_exec 'xcodebuild -version 2>/dev/null | head -n 1 | awk "{print \$2}"' || echo "")
  if [ -z "$remote_xcode" ]; then
    drift+=("xcode_unavailable: xcodebuild missing on $WORKER_ID")
  else
    # Lexicographic compare on dotted versions is good enough for the
    # common case (15.4 vs 15.4.1 vs 16.0). The only false-positive is
    # 9.x vs 10.x — irrelevant for current Xcode.
    if [ "$(printf '%s\n%s\n' "$XCODE_MIN" "$remote_xcode" | sort -V | head -n 1)" != "$XCODE_MIN" ]; then
      drift+=("xcode_below_min: $WORKER_ID has $remote_xcode, manifest wants ≥$XCODE_MIN")
    fi
  fi
fi

# ---------- emit drift event if any ----------
if [ "${#drift[@]}" -gt 0 ]; then
  drift_json=$(printf '%s\n' "${drift[@]}" | jq -R . | jq -s -c .)
  emit_event_keyed sync worker worker_sync_drift_detected "$WORKER_ID" \
    "{\"studio.dispatch.node\":\"$WORKER_ID\",\"studio.sync.drift\":$drift_json}" \
    >/dev/null 2>&1 || true
  printf 'sync-worker: drift detected on %s:\n' "$WORKER_ID"
  for d in "${drift[@]}"; do printf '  - %s\n' "$d"; done
fi

# ---------- completion ----------
if [ "$DRY_RUN" = "1" ]; then
  printf 'sync-worker: DRY-RUN complete for %s — would have applied %d change(s)\n' "$WORKER_ID" "${#want_install[@]}"
fi
emit_event_keyed sync worker worker_sync_completed "$WORKER_ID" \
  "{\"studio.dispatch.node\":\"$WORKER_ID\",\"studio.sync.applied_count\":$applied,\"studio.sync.drift_count\":${#drift[@]}}" \
  >/dev/null 2>&1 || true
printf 'sync-worker: %s — applied %d, drift %d, optional-missing %d\n' \
  "$WORKER_ID" "$applied" "${#drift[@]}" "${#optional_missing[@]}"
exit 0
