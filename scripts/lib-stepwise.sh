#!/usr/bin/env bash
# lib-stepwise.sh — per-step validate-and-recover primitive for wizards.
#
# Used by scripts/bootstrap.sh (write side) and scripts/configure.sh recheck
# (read + re-validate side). The library is the seam that turns post-flight
# self-test into per-step interactive recovery.
#
# Exposes:
#   stepwise_state_path             prints absolute path to bootstrap-state.json
#   stepwise_state_init             ensures the file exists with empty schema
#   stepwise_record <id> <status> [notes]
#                                   records the result of a step ("ok",
#                                   "fail", "skipped:<reason>", "aborted")
#   stepwise_status <id>            prints current recorded status of a step
#                                   (or empty string if never recorded)
#   stepwise_recover_menu <id> <reason>
#                                   prints a 4-option recovery menu, reads
#                                   one keystroke, prints the chosen action
#                                   on stdout: retry | fix | skip | abort
#   stepwise_validate_pubkey <line>
#                                   parses an authorized_keys line via
#                                   ssh-keygen -l. On success: prints
#                                   "<bits> <fingerprint> <comment>" and
#                                   returns 0. On failure: prints reason
#                                   to stderr and returns 1.
#   stepwise_resolve_host <bare>    resolves a hostname or appends .local
#                                   if the bare form doesn't resolve.
#                                   Prints the working name on stdout, the
#                                   IP it resolved to on FD 2 (info), and
#                                   returns 0/1 for resolved/unresolved.
#   stepwise_validate <id>          re-runs the validate logic for a known
#                                   step-id. Returns 0 on pass, 1 on fail,
#                                   2 if the step-id is unknown.
#   stepwise_recheck_all <role> <worker_roles_csv>
#                                   walks every step that should pass for
#                                   the given role + worker_roles, prints
#                                   a status table, returns 0 if every
#                                   currently-failing step is unchanged
#                                   from last record (no regressions).
#
# State file shape (~/.dev-studio/.runtime/bootstrap-state.json):
#   {
#     "schema": 1,
#     "machine_id": "<uuid>",
#     "role": "manager|worker|dual",
#     "worker_roles": ["swift-test", "xcodebuild"],
#     "last_run": "2026-04-25T21:09:12Z",
#     "steps": {
#       "<step-id>": { "status": "ok|fail|skipped:<reason>|aborted",
#                      "notes": "free-form",
#                      "ts": "<iso8601>" }
#     }
#   }
#
# Why state lives at runtime-global: bootstrap-state describes machine state,
# not project state. A worker has one role-state regardless of how many
# studio-managed iOS projects the manager later registers it against.

set -u
umask 022

# Source path resolver if not already loaded.
_LSW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_LSW_REPO_ROOT="$(cd "$_LSW_DIR/.." && pwd)"
if ! command -v resolve_runtime_global >/dev/null 2>&1; then
  # shellcheck source=lib-paths.sh
  . "$_LSW_DIR/lib-paths.sh"
fi

stepwise_state_path() {
  printf '%s/bootstrap-state.json' "$(resolve_runtime_global)"
}

stepwise_state_init() {
  local p; p=$(stepwise_state_path)
  if [ ! -f "$p" ]; then
    mkdir -p "$(dirname "$p")"
    printf '{"schema":1,"steps":{}}\n' > "$p"
  fi
}

# stepwise_record <step-id> <status> [notes]
stepwise_record() {
  local id="${1:?step-id required}" status="${2:?status required}" notes="${3:-}"
  local p; p=$(stepwise_state_path)
  stepwise_state_init
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp; tmp=$(mktemp)
  if jq --arg id "$id" --arg s "$status" --arg n "$notes" --arg ts "$ts" \
       '.steps[$id] = {status: $s, notes: $n, ts: $ts}' "$p" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$p"
  else
    rm -f "$tmp"
    return 1
  fi
}

# stepwise_status <step-id>  → prints "ok" | "fail" | "skipped:..." | "" if absent
stepwise_status() {
  local id="${1:?step-id required}"
  local p; p=$(stepwise_state_path)
  [ -f "$p" ] || return 0
  jq -r --arg id "$id" '.steps[$id]?.status // ""' "$p" 2>/dev/null
}

# stepwise_recover_menu <step-id> <reason>
# Prints a 4-line menu to FD 3 (terminal — bypasses tee), reads from FD 4,
# prints chosen action on stdout: retry | fix | skip | abort.
# Falls back to stderr/stdin when FDs 3/4 aren't open.
stepwise_recover_menu() {
  local id="${1:?step-id required}" reason="${2:?reason required}"
  local out_fd in_fd reply
  if { : >&3; } 2>/dev/null; then out_fd=3; else out_fd=2; fi
  if { : <&4; } 2>/dev/null; then in_fd=4; else in_fd=0; fi
  {
    printf '\n  \033[31m✗\033[0m Step "%s" failed: %s\n' "$id" "$reason"
    printf '\n'
    printf '    [r] retry — re-run this step\n'
    printf '    [f] fix it now — open the relevant tool ($EDITOR / App Store / browser) and we re-validate after\n'
    printf '    [s] skip with warning — proceed; mark step as skipped\n'
    printf '    [a] abort — save state; resume later with `scripts/bootstrap.sh --resume`\n'
    printf '\n'
    printf '  \033[1;33m⌨  CHOOSE\033[0m  [r/f/s/a]: '
  } >&"$out_fd"
  IFS= read -r reply <&"$in_fd" || reply="a"
  case "$reply" in
    r|R|retry) echo retry ;;
    f|F|fix)   echo fix ;;
    s|S|skip)  echo skip ;;
    a|A|abort|"") echo abort ;;
    *)         echo abort ;;
  esac
}

# stepwise_validate_pubkey <line>
# Parses one authorized_keys-style line and prints "<bits> <fingerprint> <comment>"
# on stdout. Returns 0 if valid, 1 if not.
stepwise_validate_pubkey() {
  local line="${1:-}"
  [ -z "$line" ] && { printf 'empty pubkey\n' >&2; return 1; }
  case "$line" in ssh-*|ecdsa-sha2-*|sk-ssh-*) ;; *) printf 'not an ssh-* key line\n' >&2; return 1 ;; esac
  # ssh-keygen -l reads from a file or stdin via -f -. Use a temp because
  # `<<<` would inject a trailing newline that's harmless but feels brittle.
  local tmp parsed
  tmp=$(mktemp)
  printf '%s\n' "$line" > "$tmp"
  parsed=$(ssh-keygen -l -f "$tmp" 2>/dev/null) || { rm -f "$tmp"; printf 'ssh-keygen could not parse the line\n' >&2; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$parsed"
  return 0
}

# stepwise_resolve_host <bare-host>
# Returns a working hostname on stdout. Resolution preference:
#   1. Tailscale magic-DNS name if Tailscale is up + this host is in tailnet
#   2. <bare> if it resolves
#   3. <bare>.local if that resolves
#   4. <bare> as-is + nonzero exit (caller decides what to do)
# Resolution probe uses dscacheutil first, getent as fallback (Linux compat),
# host(1) as last resort.
stepwise_resolve_host() {
  local bare="${1:?bare hostname required}"
  local resolved=""
  _lsw_resolves() {
    local h="$1"
    if command -v dscacheutil >/dev/null 2>&1; then
      dscacheutil -q host -a name "$h" 2>/dev/null | grep -q '^ip_address:' && return 0
    fi
    if command -v getent >/dev/null 2>&1; then
      getent hosts "$h" >/dev/null 2>&1 && return 0
    fi
    if command -v host >/dev/null 2>&1; then
      host -W 2 "$h" >/dev/null 2>&1 && return 0
    fi
    return 1
  }
  # Tailscale magic-DNS
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    local ts_name
    ts_name=$(tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))
except Exception: pass' 2>/dev/null || true)
    if [ -n "$ts_name" ] && _lsw_resolves "$ts_name"; then
      resolved="$ts_name"
    fi
  fi
  if [ -z "$resolved" ] && _lsw_resolves "$bare"; then
    resolved="$bare"
  fi
  if [ -z "$resolved" ] && _lsw_resolves "${bare}.local"; then
    resolved="${bare}.local"
  fi
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  printf '%s\n' "$bare"
  return 1
}

# stepwise_validate <step-id>
# Centralized re-validation logic. Runs the validate hook for a known step.
# Returns 0 pass, 1 fail, 2 unknown step-id.
# Used by configure.sh recheck and bootstrap self-test.
stepwise_validate() {
  local id="${1:?step-id required}"
  case "$id" in
    skill_dev_studio)      test -L "$_LSW_REPO_ROOT/.claude/skills/dev-studio" ;;
    brew)                  command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ] ;;
    jq)                    command -v jq >/dev/null 2>&1 ;;
    rsync)                 command -v rsync >/dev/null 2>&1 ;;
    git)                   command -v git >/dev/null 2>&1 ;;
    git_user_email)        [ -n "$(git config --global user.email 2>/dev/null)" ] ;;
    sshd)                  launchctl list 2>/dev/null | grep -qi ssh ;;
    clt)                   xcode-select -p >/dev/null 2>&1 ;;
    xcode_app)             [ -e /Applications/Xcode.app ] ;;
    swift)                 command -v swift >/dev/null 2>&1 ;;
    yq)                    command -v yq >/dev/null 2>&1 ;;
    coreutils)             command -v gtimeout >/dev/null 2>&1 ;;
    fswatch)               command -v fswatch >/dev/null 2>&1 ;;
    nodes_json)            [ -f "$HOME/.dev-studio/.runtime/nodes.json" ] ;;
    *) return 2 ;;
  esac
}

# stepwise_recheck_all <role> <worker_roles_csv>
# Walks the step list relevant to the given role + worker_roles and prints
# one row per step: <id> <current> <recorded> <hint-if-actionable>.
# Returns 0 if no regressions vs recorded, 1 otherwise.
stepwise_recheck_all() {
  local role="${1:?role required}" wroles="${2:-}"
  stepwise_state_init
  local -a steps=()
  case "$role" in
    manager|dual)
      steps+=(skill_dev_studio brew jq yq coreutils fswatch git git_user_email nodes_json)
      ;;
  esac
  case "$role" in
    worker|dual)
      steps+=(sshd jq rsync coreutils git brew clt)
      case ",$wroles," in *,xcodebuild,*) steps+=(xcode_app) ;; esac
      case ",$wroles," in *,swift-test,*) steps+=(swift) ;; esac
      ;;
  esac
  # Dedupe while preserving order.
  local -a uniq=(); local s
  for s in "${steps[@]}"; do
    case " ${uniq[*]:-} " in *" $s "*) ;; *) uniq+=("$s") ;; esac
  done
  local regressions=0 first_seen_pass=0
  printf '%-22s %-8s %-12s %s\n' "STEP" "NOW" "WAS" "NOTE"
  printf '%-22s %-8s %-12s %s\n' "----" "---" "---" "----"
  for s in "${uniq[@]}"; do
    local now was rc
    if stepwise_validate "$s"; then now=pass; rc=0; else now=fail; rc=1; fi
    was=$(stepwise_status "$s")
    [ -z "$was" ] && was="(none)"
    local note=""
    if [ "$now" = "pass" ] && [ "$was" = "fail" ]; then
      note="↑ newly passing — re-enable any role gated on this step"
      first_seen_pass=$((first_seen_pass + 1))
    elif [ "$now" = "fail" ] && [ "$was" = "ok" ]; then
      note="↓ regression"
      regressions=$((regressions + 1))
    elif [ "$now" = "fail" ] && [ "$was" = "(none)" ]; then
      note="never validated; first observation = fail"
    fi
    printf '%-22s %-8s %-12s %s\n' "$s" "$now" "$was" "$note"
    # Update state file with current observation (so subsequent recheck tracks
    # newest-known-good as the comparison point).
    if [ "$rc" = "0" ]; then
      stepwise_record "$s" "ok" "" || true
    fi
  done
  echo
  if [ "$first_seen_pass" -gt 0 ]; then
    printf 'recheck: %d step(s) newly passing\n' "$first_seen_pass"
  fi
  if [ "$regressions" -gt 0 ]; then
    printf 'recheck: %d regression(s) — investigate\n' "$regressions" >&2
    return 1
  fi
  return 0
}
