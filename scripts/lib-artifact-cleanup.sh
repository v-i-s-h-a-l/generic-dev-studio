#!/usr/bin/env bash
# lib-artifact-cleanup.sh — shared cleanup primitive for studio scripts.
#
# Sourced by callers that produce disposable runtime artifacts (tmp dirs,
# scratch files, xcresult bundles, derived data, log files) and want them
# torn down deterministically when the calling shell exits — successful or
# not. Replaces hand-rolled `trap 'rm -rf "$tmp"' EXIT` snippets that drift
# in subtle ways across callers (kind, retention, host-flip handoff).
#
# API:
#   register_artifact <kind> <path> [--keep-on-handoff]
#       Track <path> for cleanup at shell exit. <kind> is a short label
#       ("xcresult", "tmpdir", "log", "derived-data") used for the audit
#       line and registry metadata. --keep-on-handoff transfers ownership
#       to the registry's handoff dir (the artifact is NOT deleted by this
#       process; a follow-up chained task is expected to consume it and
#       run its own cleanup). The EXIT trap is installed lazily on the
#       first register_artifact call — the file is side-effect-free until
#       then, so any studio script can source it unconditionally.
#
#   finalize_artifacts
#       Idempotent. Walks the in-memory registry and either deletes,
#       hands off, or audits each entry. Normally invoked automatically
#       by the EXIT trap; callers can invoke it directly for early
#       teardown (e.g. before re-exec).
#
# Environment:
#   STUDIO_KEEP_ARTIFACTS=1
#       Retain everything; emit a stderr audit line per artifact and
#       skip both deletion and handoff. Useful for post-mortem
#       inspection without smearing a half-finalized state into the
#       handoff dir.
#
# Path policy:
#   The handoff registry dir is derived via resolve_project_root from
#   scripts/lib-paths.sh; raw runtime-path formulas are forbidden in
#   this file (lint-runtime-paths.sh would block such a line).
#
# Sourceability:
#   No `set -e` here; callers may or may not run with strict mode.
#   No EXIT trap installed at source time — only the first
#   register_artifact call wires it up.

# Idempotent re-source guard. Sourcing the file twice (e.g. through two
# different libraries) must not reset the in-memory registry or stack
# duplicate EXIT traps.
if [ -n "${_STUDIO_ARTIFACT_CLEANUP_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_STUDIO_ARTIFACT_CLEANUP_LOADED=1

# Resolve lib-paths.sh relative to this script. BASH_SOURCE-aware so
# `source scripts/lib-artifact-cleanup.sh` from any cwd works.
_lac_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
  cd "$(dirname "$src")" 2>/dev/null && pwd
}

# Source lib-paths.sh once, lazily. Sourcing a second time is a no-op
# in practice (its functions get redefined to identical bodies) but we
# guard anyway to keep this file's "no side effects until used"
# contract crisp.
_lac_load_paths() {
  if [ -n "${_LAC_PATHS_LOADED:-}" ]; then
    return 0
  fi
  local dir
  dir=$(_lac_script_dir) || return 1
  # shellcheck source=/dev/null
  . "$dir/lib-paths.sh" || return 1
  _LAC_PATHS_LOADED=1
}

# Parallel arrays scoped to this process. Index N across both arrays
# describes one registered artifact.
_LAC_KINDS=()
_LAC_PATHS=()
_LAC_HANDOFFS=()    # "1" if --keep-on-handoff was passed, else "0"
_LAC_TRAP_INSTALLED=0
_LAC_FINALIZED=0

_lac_install_trap() {
  [ "$_LAC_TRAP_INSTALLED" -eq 1 ] && return 0
  # Composed trap: preserve any pre-existing EXIT trap by chaining it.
  # Callers that already set their own EXIT handler keep it; ours runs
  # alongside.
  local existing
  existing=$(trap -p EXIT 2>/dev/null | sed -n "s/^trap -- '\(.*\)' EXIT$/\1/p")
  if [ -n "$existing" ]; then
    # shellcheck disable=SC2064 # intentional early expansion of $existing
    trap "$existing; finalize_artifacts" EXIT
  else
    trap finalize_artifacts EXIT
  fi
  _LAC_TRAP_INSTALLED=1
}

# Build the handoff registry dir. Lazily created (mkdir -p) only when
# we actually need to write a handoff record, so register_artifact
# without --keep-on-handoff stays filesystem-quiet on the registry side.
_lac_registry_dir() {
  _lac_load_paths || return 1
  local root
  root=$(resolve_project_root 2>/dev/null) || return 1
  printf '%s\n' "$root/.runtime/state/artifact-cleanup"
}

# Public: register an artifact for end-of-shell cleanup.
register_artifact() {
  if [ "$#" -lt 2 ]; then
    printf 'register_artifact: usage: register_artifact <kind> <path> [--keep-on-handoff]\n' >&2
    return 2
  fi
  # NOTE: never use `local path` here — zsh ties `path` to `PATH`, so a
  # local would temporarily wipe PATH inside this function and any trap
  # callees, breaking command lookup for sed/rm/etc. Use art_path.
  local kind="$1" art_path="$2" handoff="0"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep-on-handoff) handoff="1"; shift ;;
      *)
        printf 'register_artifact: unknown flag: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  if [ -z "$kind" ] || [ -z "$art_path" ]; then
    printf 'register_artifact: <kind> and <path> must be non-empty\n' >&2
    return 2
  fi

  _LAC_KINDS+=("$kind")
  _LAC_PATHS+=("$art_path")
  _LAC_HANDOFFS+=("$handoff")
  _lac_install_trap
}

# Stamp a handoff record so a follow-up chained task can find the
# artifact and own its lifecycle. TSV (kind, path, owner_pid, ts_iso)
# keeps the format greppable without a yq/jq dependency.
_lac_write_handoff_record() {
  # zsh-safe: art_path instead of path.
  local kind="$1" art_path="$2"
  local dir record ts
  dir=$(_lac_registry_dir) || return 1
  mkdir -p "$dir/handoff" 2>/dev/null || return 1
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  # One file per record so concurrent writers from sibling processes
  # never clobber each other; filename is unique per (pid, count).
  record="$dir/handoff/$$-${#_LAC_KINDS[@]}-$(date +%s 2>/dev/null || echo n).tsv"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$art_path" "$$" "$ts" > "$record" 2>/dev/null
}

# Public: finalize all registered artifacts. Safe to call multiple times.
finalize_artifacts() {
  [ "$_LAC_FINALIZED" -eq 1 ] && return 0
  _LAC_FINALIZED=1

  local keep_all="0"
  case "${STUDIO_KEEP_ARTIFACTS:-0}" in
    1|true|TRUE|yes|YES) keep_all="1" ;;
  esac

  # Portable iteration across bash (0-indexed) and zsh (1-indexed by
  # default): walk the parallel arrays via the @ expansion plus a counter
  # we maintain ourselves, so we never index by an integer that differs
  # between shells. zsh-safe: art_path instead of path.
  local kind art_path handoff
  local idx=0
  for art_path in "${_LAC_PATHS[@]}"; do
    if [ -n "${ZSH_VERSION:-}" ]; then
      kind="${_LAC_KINDS[$((idx + 1))]}"
      handoff="${_LAC_HANDOFFS[$((idx + 1))]}"
    else
      kind="${_LAC_KINDS[$idx]}"
      handoff="${_LAC_HANDOFFS[$idx]}"
    fi

    if [ "$keep_all" = "1" ]; then
      printf 'studio: STUDIO_KEEP_ARTIFACTS=1 — retaining %s artifact: %s\n' \
        "$kind" "$art_path" >&2
    elif [ "$handoff" = "1" ]; then
      _lac_write_handoff_record "$kind" "$art_path" || true
      # Intentionally NO rm — ownership transferred.
    else
      if [ -n "$art_path" ] && [ -e "$art_path" ]; then
        rm -rf -- "$art_path" 2>/dev/null || true
      fi
    fi
    idx=$((idx + 1))
  done
}
