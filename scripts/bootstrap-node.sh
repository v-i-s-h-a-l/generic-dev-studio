#!/usr/bin/env bash
# bootstrap-node.sh — interactive worker-node onboarding wizard.
#
# Run this ONCE on the Mac you're onboarding as a worker node (mini,
# studio, any headless host). It walks through every step — auto-runs
# what it can, pauses for the manual bits (Xcode install, Tailscale
# browser login, pasting the laptop's pubkey), and finishes by printing
# the exact `nodes.json` entry to add on your laptop.
#
# Host-agnostic: no hardcoded "mini" anywhere. Defaults come from the
# host's own identity (hostname, username). Works on any macOS host.
#
# Usage:
#   ./scripts/bootstrap-node.sh              # interactive (normal)
#   ./scripts/bootstrap-node.sh --dry-run    # show what would happen; change nothing
#   ./scripts/bootstrap-node.sh --help
#
# Exit codes:
#   0  finished — node is registered-ready; paste the printed entry on the laptop
#   1  preflight failure (not macOS, or running as root)
#   2  aborted by user

set -u
umask 022

# ---------- ANSI helpers ----------
if [ -t 1 ]; then
  c_cyan=$'\033[1;36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
else
  c_cyan=''; c_green=''; c_yellow=''; c_blue=''; c_red=''; c_dim=''; c_reset=''
fi

step()     { printf '\n%s━━━ %s ━━━%s\n' "$c_cyan" "$*" "$c_reset"; }
ok()       { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()     { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$*"; }
info()     { printf '  %si%s %s\n' "$c_blue" "$c_reset" "$*"; }
err()      { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
cmd_hint() { printf '  %s$ %s%s\n' "$c_dim" "$*" "$c_reset"; }

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      # Echo the header block (lines 2 up to the first blank comment)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "unknown flag: $arg"; exit 1 ;;
  esac
done

ask() {
  # ask "prompt" [default] → stdout = reply (or default)
  local prompt="$1" default="${2:-}" suffix reply
  [ -n "$default" ] && suffix=" [$default]" || suffix=""
  read -rp "  ? $prompt$suffix: " reply
  printf '%s' "${reply:-$default}"
}

confirm() {
  # confirm "prompt" [default=y|n] → exit 0 if yes
  local prompt="$1" default="${2:-y}" suffix reply
  case "$default" in y|Y) suffix="[Y/n]" ;; *) suffix="[y/N]" ;; esac
  read -rp "  ? $prompt $suffix: " reply
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

pause_for_user() {
  read -rp "  ↵ Press Enter when done (or Ctrl-C to abort)..." _
}

run() {
  # Invoke a command, respecting --dry-run. Quotes preserved.
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %sDRY-RUN:%s %s\n' "$c_dim" "$c_reset" "$*"
    return 0
  fi
  "$@"
}

# ---------- preflight ----------
step "Preflight"
if [ "$(uname)" != "Darwin" ]; then
  err "This script is macOS-only (detected: $(uname))."
  err "Linux worker support will land in a later iteration — for now, do the manual steps in .claude/skills/studio/node-setup.html."
  exit 1
fi
ok "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

if [ "${EUID:-$(id -u)}" = "0" ]; then
  err "Don't run this script as root. It'll prompt for sudo where needed."
  exit 1
fi
ok "running as: $(id -un)"

# ---------- 1/8 · identity ----------
step "1/8 · Node identity"
info "The node needs a short id (used in your laptop's nodes.json and in lock / event paths)."
DETECTED_HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
NODE_ID=$(ask "Node id" "$DETECTED_HOST")

info "Role tags the node can serve:"
info "  swift-test          — runs 'swift test' (needs Swift toolchain)"
info "  xcodebuild          — runs full Xcode builds (needs Xcode.app + simulators)"
info "  snapshot-canonical  — generates canonical snapshot-test reference images"
ROLES=$(ask "Roles (comma-separated)" "swift-test,xcodebuild")
ok "id:    $NODE_ID"
ok "roles: $ROLES"

# ---------- 2/8 · tailscale ----------
step "2/8 · Tailscale"
info "Tailscale gives this node a stable mesh-network hostname reachable from your laptop anywhere."
info "Free for personal use. If your laptop + node are on the same LAN and you never leave, you can skip it and use mini.local / LAN IPs — but Tailscale is the recommended path."

TS_INSTALLED=0; TS_UP=0
if command -v tailscale >/dev/null 2>&1; then
  TS_INSTALLED=1
  if tailscale status >/dev/null 2>&1; then
    TS_UP=1; ok "Tailscale installed and logged in"
  else
    warn "Tailscale installed but not logged in"
  fi
elif [ -e /Applications/Tailscale.app ]; then
  TS_INSTALLED=1
  warn "Tailscale.app installed but CLI not on PATH"
else
  warn "Tailscale not installed"
fi

if [ "$TS_INSTALLED" = "0" ]; then
  if confirm "Install Tailscale now?"; then
    if command -v brew >/dev/null 2>&1; then
      run brew install --cask tailscale
      TS_INSTALLED=1
    else
      info "Homebrew isn't installed yet (that's step 6). Two options:"
      info "  (a) Skip Tailscale now, install it after step 6"
      info "  (b) Download the app manually from https://tailscale.com/download/mac"
      if confirm "Download the app manually in your browser now?"; then
        run open "https://tailscale.com/download/mac"
        info "Install Tailscale.app, then open it and sign in."
        pause_for_user
        TS_INSTALLED=1
      fi
    fi
  else
    info "Skipping. You can add Tailscale later; the script continues."
  fi
fi

if [ "$TS_INSTALLED" = "1" ] && [ "$TS_UP" = "0" ]; then
  info "Start Tailscale + sign in with the SAME account you use on the laptop."
  cmd_hint "open -a Tailscale      # click through the GUI sign-in"
  cmd_hint "# or: sudo tailscale up   (if the CLI is installed)"
  pause_for_user
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    ok "Tailscale up"; TS_UP=1
  else
    warn "Still not detected as up. Continuing; you can sort it out later."
  fi
fi

# Resolve the hostname we'll use in nodes.json
TS_HOST=""
if [ "$TS_UP" = "1" ] && command -v tailscale >/dev/null 2>&1; then
  TS_HOST=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("Self",{}).get("HostName",""))
except Exception: pass' 2>/dev/null || true)
fi
if [ -z "$TS_HOST" ]; then
  TS_HOST="$DETECTED_HOST"
  info "Using local hostname: $TS_HOST (add .local or a LAN IP in nodes.json if needed)"
else
  ok "Tailscale hostname: $TS_HOST"
fi

# ---------- 3/8 · SSH ----------
step "3/8 · SSH (Remote Login)"
info "Enables incoming SSH so your laptop can dispatch commands here."
if sudo -n true 2>/dev/null; then
  sudo_status="cached"
else
  sudo_status="will prompt"
  info "You'll be asked for your sudo password next."
fi
_remote_login_state() {
  sudo systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print tolower($NF)}' | tr -d ' '
}
if [ "$(_remote_login_state)" = "on" ]; then
  ok "Remote Login already enabled"
else
  if run sudo systemsetup -setremotelogin on; then
    ok "Remote Login enabled"
  else
    warn "Couldn't enable via CLI."
    info "Fallback: System Settings → General → Sharing → Remote Login: ON"
    pause_for_user
  fi
fi

# ---------- 4/8 · pubkey ----------
step "4/8 · Accept your laptop's SSH pubkey"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

info "On your LAPTOP (different terminal / different machine), run ONE of:"
cmd_hint "cat ~/.ssh/id_ed25519.pub"
cmd_hint "cat ~/.ssh/id_rsa.pub"
info "Copy the output (one line starting with ssh-ed25519 or ssh-rsa)."
info "Paste it here, press Enter, then Ctrl-D to finish."
echo

if [ "$DRY_RUN" = "1" ]; then
  info "DRY-RUN: would read pubkey from stdin and append to ~/.ssh/authorized_keys"
else
  pubkey=$(cat | tr -d '\r' | head -n 1 | sed 's/[[:space:]]*$//')
  if [ -z "$pubkey" ]; then
    warn "No pubkey pasted. You'll need to add it manually later:"
    cmd_hint "echo 'ssh-ed25519 ...' >> ~/.ssh/authorized_keys"
  elif [ "${pubkey#ssh-}" = "$pubkey" ]; then
    warn "That doesn't look like an SSH public key (expected 'ssh-ed25519 …' or 'ssh-rsa …')"
    warn "Skipping — add it manually later."
  elif grep -qF "$pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
    ok "That key is already in authorized_keys — no change"
  else
    printf '%s\n' "$pubkey" >> ~/.ssh/authorized_keys
    ok "Pubkey appended to ~/.ssh/authorized_keys"
  fi
fi

# ---------- 5/8 · Xcode / CLT ----------
step "5/8 · Xcode toolchain"
if xcode-select -p >/dev/null 2>&1; then
  ok "CLT / Xcode at: $(xcode-select -p)"
  if command -v xcodebuild >/dev/null 2>&1; then
    info "$(xcodebuild -version 2>/dev/null | head -n 1)"
  fi
  if command -v swift >/dev/null 2>&1; then
    info "$(swift --version 2>/dev/null | head -n 1)"
  fi
else
  warn "Command Line Tools not installed"
  if confirm "Run 'xcode-select --install' now?"; then
    run xcode-select --install || true
    info "A GUI installer should open. Wait for it to finish, then press Enter."
    pause_for_user
  fi
fi

case ",$ROLES," in
  *,xcodebuild,*)
    if [ ! -e /Applications/Xcode.app ]; then
      warn "Role 'xcodebuild' requested but /Applications/Xcode.app not found."
      info "Install full Xcode from the App Store, or from:"
      cmd_hint "open 'https://developer.apple.com/download/all/?q=Xcode'"
      info "After install, point xcode-select at it:"
      cmd_hint "sudo xcode-select -s /Applications/Xcode.app"
      info "Also install the simulator runtimes your laptop uses:"
      cmd_hint "open -a Xcode      # Settings → Platforms"
    else
      ok "/Applications/Xcode.app present"
      info "Check simulator runtimes match the laptop's:"
      cmd_hint "xcrun simctl list runtimes"
    fi
    ;;
esac

# ---------- 6/8 · brew + packages ----------
step "6/8 · Homebrew + required packages"
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew: $(brew --version | head -n 1)"
else
  warn "Homebrew not installed"
  if confirm "Install Homebrew (runs the official installer)?"; then
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$bp" ] && eval "$("$bp" shellenv)" && break
    done
  fi
fi

if command -v brew >/dev/null 2>&1; then
  # jq/rsync/coreutils/fswatch/git are the packages studio scripts rely on.
  for pkg in jq rsync coreutils fswatch git; do
    if brew list --formula 2>/dev/null | grep -qx "$pkg"; then
      ok "$pkg ($(brew list --versions "$pkg" 2>/dev/null | awk '{print $NF}'))"
    else
      info "Installing $pkg ..."
      run brew install "$pkg"
    fi
  done
else
  warn "No brew available — skipping package install. Revisit after installing brew manually."
fi

# ---------- 7/8 · pmset ----------
step "7/8 · Keep the node awake"
info "A worker node should never auto-sleep while idle. Recommended:"
cmd_hint "sudo pmset -a sleep 0 displaysleep 10 disksleep 0"
if confirm "Apply now?"; then
  run sudo pmset -a sleep 0 displaysleep 10 disksleep 0
  ok "pmset applied"
else
  info "Skipped. You can apply the command above whenever."
fi

# For always-on (office) machines, surface the extra flags — informational.
if confirm "Is this an ALWAYS-ON machine (office studio, hosted box)?" "n"; then
  info "Extra flags for always-on use:"
  cmd_hint "sudo pmset -a autorestart 1            # auto-boot after power loss"
  cmd_hint "sudo tailscaled install-system-daemon  # Tailscale as system service"
  info "See node-setup.html §Always-on node for the full checklist + security considerations."
fi

# ---------- 8/8 · registration ----------
step "8/8 · Registration (do this on your LAPTOP)"
CURRENT_USER=$(id -un)

# Build JSON roles array without depending on jq (jq may not be installed yet).
roles_json=$(printf '%s' "$ROLES" | awk -F',' 'BEGIN{printf "["}
{
  for (i=1;i<=NF;i++) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
    if (length($i)==0) continue
    if (cnt++) printf ", "
    printf "\"%s\"", $i
  }
} END{printf "]"}')

cat <<BANNER

${c_cyan}═══ COPY-PASTE TO YOUR LAPTOP ═══${c_reset}

${c_dim}# File: ~/.dev-studio/.runtime/nodes.json${c_reset}
${c_dim}# If it doesn't exist, create it with the whole JSON below.${c_reset}
${c_dim}# If it exists, append the inner { ... } block to the "nodes" array.${c_reset}

{
  "schema": 1,
  "nodes": [
    {
      "id": "$NODE_ID",
      "host": "$TS_HOST",
      "user": "$CURRENT_USER",
      "roles": $roles_json,
      "enabled": true
    }
  ]
}

${c_cyan}═══ VERIFY (run on LAPTOP, from the studio repo) ═══${c_reset}

  ssh -o BatchMode=yes $CURRENT_USER@$TS_HOST true && echo OK
  scripts/node-health.sh $NODE_ID        # → "$NODE_ID ... healthy ..."
  scripts/node-pick.sh swift-test        # → $NODE_ID
  scripts/node-dispatch.sh $NODE_ID echo "hello from \$(hostname)"

BANNER

step "Done"
info "The node is ready to accept dispatches."
info "First-time remote xcodebuild will be slow (cold DerivedData + first rsync once #127 lands)."
info "Open the full guide any time with:  /studio-node-setup"
