#!/usr/bin/env bash
# node-diagnose.sh — runtime troubleshooter for remote-dispatch failures (#139).
#
# When `node-pick` returns `local` unexpectedly, or a remote dispatch fails,
# this script walks every check from setup.html §Troubleshoot for one (or
# every enabled) registered node, printing pass / fail / n/a + reason and,
# on failure, the exact fix command.
#
# Usage:
#   scripts/node-diagnose.sh                       # every enabled node
#   scripts/node-diagnose.sh <node-id>             # one node (any state)
#   scripts/node-diagnose.sh <node-id> --role <r>  # also assert role advertised
#
# Exit codes:
#   0   every check passed (or n/a)
#   N   N checks failed (across all probed nodes)
#   2   bad args / registry parse error / required tools missing
#
# Checks (per node):
#   1. registered     — id present in nodes.json
#   2. enabled        — node not flagged disabled
#   3. ping           — host reachable on the network
#   4. ssh            — BatchMode SSH connect succeeds
#   5. uptime         — full ssh round-trip with `uptime`
#   6. roles          — roles array non-empty (and contains --role if given)
#   7. authorized_keys — laptop pubkey present on node
#   8. tooling        — jq + rsync present on node
#   9. xcode          — xcodebuild version delta vs this machine

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET_ID=""
REQUIRED_ROLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --role)    REQUIRED_ROLE="${2:-}"; shift 2 ;;
    --role=*)  REQUIRED_ROLE="${1#--role=}"; shift ;;
    -*) printf 'error: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)  if [ -z "$TARGET_ID" ]; then TARGET_ID="$1"; shift
        else printf 'error: extra arg %s\n' "$1" >&2; exit 2; fi ;;
  esac
done

REGISTRY="$(resolve_runtime_global)/nodes.json"
PARITY_CACHE="$(resolve_runtime_global)/node-parity-cache.json"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Pubkey location convention — setup.html §Troubleshoot anchors on
# id_ed25519.pub. id_rsa.pub is the legacy fallback for older laptops.
LOCAL_PUBKEY=""
for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -r "$cand" ] && { LOCAL_PUBKEY="$cand"; break; }
done

SSH_OPTS=(
  -n
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
)
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 10"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 10"

FAIL_COUNT=0

# Render one check line. Tag is one of: ok | fail | n/a | warn.
# `fix` is printed under the line on fail/warn — empty string suppresses it.
emit() {
  local tag="$1" name="$2" reason="$3" fix="${4:-}"
  case "$tag" in
    ok)   printf '  [  ok  ] %-18s %s\n' "$name" "$reason" ;;
    fail) printf '  [ FAIL ] %-18s %s\n' "$name" "$reason"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    warn) printf '  [ warn ] %-18s %s\n' "$name" "$reason" ;;
    n/a)  printf '  [ n/a  ] %-18s %s\n' "$name" "$reason" ;;
  esac
  [ -n "$fix" ] && printf '             fix: %s\n' "$fix"
}

# Pull every enabled node id, or the explicit target. Empty if registry
# missing — caller short-circuits on that.
list_target_ids() {
  if [ ! -r "$REGISTRY" ]; then return 0; fi
  if [ -n "$TARGET_ID" ]; then
    printf '%s\n' "$TARGET_ID"
    return 0
  fi
  jq -r '.nodes[]? | select(.enabled != false) | .id' "$REGISTRY" 2>/dev/null
}

# Run the diagnostic for one id. Self-host short-circuits the network /
# ssh / pubkey checks (n/a) and runs tooling + xcode locally.
diagnose_one() {
  local id="$1"
  printf '\nnode: %s\n' "$id"

  # ---- 1. registered ----
  local row host user_ enabled roles_csv
  if [ ! -r "$REGISTRY" ]; then
    emit fail registered "no registry at $REGISTRY" \
      "scripts/bootstrap.sh --worker  # creates the registry on the manager"
    return
  fi
  row=$(jq -r --arg id "$id" \
    '.nodes[]? | select(.id == $id) | [.id, (.host // "-"), (.user // "-"), (if .enabled == false then "false" else "true" end), ((.roles // []) | join(","))] | @tsv' \
    "$REGISTRY" 2>/dev/null)
  if [ -z "$row" ]; then
    emit fail registered "id '$id' not in $REGISTRY" \
      "scripts/configure.sh worker add  # interactive register"
    return
  fi
  IFS=$'\t' read -r _ host user_ enabled roles_csv <<<"$row"
  emit ok registered "host=$host user=$user_"

  # ---- 2. enabled ----
  if [ "$enabled" = "true" ]; then
    emit ok enabled "dispatch eligible"
  else
    emit fail enabled "marked enabled:false in registry" \
      "scripts/configure.sh worker enable $id"
    # Disabled nodes can still be probed — keep walking, the user may be
    # diagnosing why they disabled it in the first place.
  fi

  local is_self=0
  node_is_self "$id" && is_self=1

  # ---- 3. ping ----
  if [ "$is_self" = "1" ]; then
    emit n/a ping "self-host — network reachability not applicable"
  elif [ "$host" = "-" ] || [ -z "$host" ]; then
    emit fail ping "no host recorded for $id" \
      "scripts/configure.sh worker add  # re-register with host"
  else
    if ping -c 1 -W 2000 "$host" >/dev/null 2>&1 \
       || ping -c 1 -t 2 "$host" >/dev/null 2>&1; then
      emit ok ping "$host responds"
    else
      emit fail ping "$host unreachable on this network" \
        "tailscale status  # both machines should list each other; re-login if offline"
    fi
  fi

  # ---- 4. ssh ----
  local ssh_ok=0
  if [ "$is_self" = "1" ]; then
    emit n/a ssh "self-host — SSH not used"
    ssh_ok=1
  elif [ "$host" = "-" ]; then
    emit fail ssh "no host recorded — see fix above" ""
  else
    if $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" true >/dev/null 2>&1; then
      emit ok ssh "BatchMode connect to ${user_}@${host} succeeds"
      ssh_ok=1
    else
      emit fail ssh "ssh ${user_}@${host} fails (BatchMode, ConnectTimeout=5)" \
        "ssh -v ${user_}@${host} true  # diagnose: Remote Login off, pubkey missing, or host-key drift"
    fi
  fi

  # ---- 5. uptime round-trip ----
  if [ "$is_self" = "1" ]; then
    emit n/a uptime "self-host — local uptime not probed"
  elif [ "$ssh_ok" = "1" ]; then
    if $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" uptime >/dev/null 2>&1; then
      emit ok uptime "remote uptime returns cleanly"
    else
      emit fail uptime "ssh connects but \`uptime\` does not return" \
        "ssh ${user_}@${host} uptime  # check shell rc files for non-interactive output"
    fi
  else
    emit fail uptime "skipped — ssh failed above" ""
  fi

  # ---- 6. roles ----
  if [ -z "$roles_csv" ]; then
    emit fail roles "roles array is empty — node-pick will never select it" \
      "scripts/configure.sh worker add  # re-register with roles"
  elif [ -n "$REQUIRED_ROLE" ]; then
    case ",$roles_csv," in
      *",$REQUIRED_ROLE,"*)
        emit ok roles "$REQUIRED_ROLE present (advertised: $roles_csv)" ;;
      *)
        emit fail roles "$REQUIRED_ROLE not in advertised roles ($roles_csv)" \
          "edit $REGISTRY: add \"$REQUIRED_ROLE\" to .nodes[] | select(.id==\"$id\") | .roles" ;;
    esac
  else
    emit ok roles "advertised: $roles_csv"
  fi

  # ---- 7. authorized_keys ----
  if [ "$is_self" = "1" ]; then
    emit n/a authorized_keys "self-host — pubkey check not applicable"
  elif [ "$ssh_ok" != "1" ]; then
    emit fail authorized_keys "skipped — ssh failed above" ""
  elif [ -z "$LOCAL_PUBKEY" ]; then
    emit warn authorized_keys "no local pubkey at ~/.ssh/id_ed25519.pub or id_rsa.pub" \
      "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519  # then ssh-copy-id ${user_}@${host}"
  else
    local publine
    publine=$(awk '{print $2}' "$LOCAL_PUBKEY" 2>/dev/null)
    if [ -n "$publine" ] && \
       $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" \
         "grep -F -q -- '$publine' ~/.ssh/authorized_keys 2>/dev/null"; then
      emit ok authorized_keys "$(basename "$LOCAL_PUBKEY") found in ${user_}@${host}:~/.ssh/authorized_keys"
    else
      emit fail authorized_keys "laptop pubkey not in ${user_}@${host}:~/.ssh/authorized_keys" \
        "ssh-copy-id -i $LOCAL_PUBKEY ${user_}@${host}"
    fi
  fi

  # ---- 8. tooling (jq + rsync) ----
  local missing=""
  if [ "$is_self" = "1" ]; then
    command -v jq    >/dev/null 2>&1 || missing="${missing}jq "
    command -v rsync >/dev/null 2>&1 || missing="${missing}rsync "
    if [ -z "$missing" ]; then
      emit ok tooling "jq + rsync present locally"
    else
      emit fail tooling "missing locally: ${missing% }" \
        "brew install ${missing% }"
    fi
  elif [ "$ssh_ok" = "1" ]; then
    # Single ssh round-trip — print which of the two are missing.
    local probe
    probe=$($TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" \
      'for t in jq rsync; do command -v $t >/dev/null 2>&1 || printf "%s " "$t"; done' \
      2>/dev/null)
    if [ -z "$probe" ]; then
      emit ok tooling "jq + rsync present on ${host}"
    else
      emit fail tooling "missing on ${host}: ${probe% }" \
        "ssh ${user_}@${host} 'brew install ${probe% }'"
    fi
  else
    emit fail tooling "skipped — ssh failed above" ""
  fi

  # ---- 9. xcode version delta vs this machine ----
  local local_xcb remote_xcb
  local_xcb=$(xcodebuild -version 2>/dev/null | sed -n '1s/^Xcode //p')
  if [ "$is_self" = "1" ]; then
    if [ -n "$local_xcb" ]; then
      emit ok xcode "Xcode $local_xcb (self — no remote delta)"
    else
      emit n/a xcode "xcodebuild not installed locally"
    fi
  elif [ "$ssh_ok" != "1" ]; then
    emit fail xcode "skipped — ssh failed above" ""
  else
    # Prefer the parity cache when fresh (<1 day) — avoids a slow remote
    # xcodebuild invocation. Falls through to live probe on any miss.
    local cache_age
    if [ -r "$PARITY_CACHE" ]; then
      cache_age=$(( $(date -u +%s) - $(mtime "$PARITY_CACHE" 2>/dev/null || echo 0) ))
      if [ "$cache_age" -lt 86400 ]; then
        remote_xcb=$(jq -r --arg id "$id" \
          '.nodes[$id].xcodebuild.version // empty' "$PARITY_CACHE" 2>/dev/null)
      fi
    fi
    if [ -z "$remote_xcb" ]; then
      remote_xcb=$($TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" \
        'xcodebuild -version 2>/dev/null | sed -n "1s/^Xcode //p"' 2>/dev/null)
    fi
    if [ -z "$remote_xcb" ]; then
      emit warn xcode "xcodebuild not installed on ${host}" \
        "ssh ${user_}@${host}  # then install Xcode from the App Store"
    elif [ -z "$local_xcb" ]; then
      emit warn xcode "remote=$remote_xcb (no local Xcode to compare against)"
    elif [ "$local_xcb" = "$remote_xcb" ]; then
      emit ok xcode "matches local — Xcode $local_xcb"
    else
      # Major-version delta is the only one #136's gate blocks on.
      local lmaj rmaj
      lmaj="${local_xcb%%.*}"; rmaj="${remote_xcb%%.*}"
      if [ "$lmaj" != "$rmaj" ]; then
        emit fail xcode "major drift: local=$local_xcb remote=$remote_xcb" \
          "scripts/node-parity.sh $id  # confirm; then align Xcode majors"
      else
        emit warn xcode "minor drift: local=$local_xcb remote=$remote_xcb (warns; #136 only blocks on major)"
      fi
    fi
  fi
}

# ---- main ----
IDS=$(list_target_ids)
if [ -z "$IDS" ]; then
  if [ -n "$TARGET_ID" ]; then
    # Target was specified but registry missing — diagnose_one will surface
    # the actionable "no registry" failure.
    diagnose_one "$TARGET_ID"
  else
    printf 'no enabled nodes registered. run: scripts/configure.sh worker add\n' >&2
    exit 2
  fi
else
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    diagnose_one "$id"
  done <<EOF
$IDS
EOF
fi

printf '\n'
if [ "$FAIL_COUNT" = "0" ]; then
  printf 'all checks passed\n'
  exit 0
fi
printf '%d check(s) failed — see fix lines above\n' "$FAIL_COUNT"
exit "$FAIL_COUNT"
