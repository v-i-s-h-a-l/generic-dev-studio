#!/usr/bin/env bash
# bootstrap.sh — unified Studio setup wizard.
#
# One interactive (or non-interactive) wizard for any machine that
# participates in the Studio, regardless of role. Replaces the prior
# bootstrap-node.sh / never-built bootstrap-laptop.sh split.
#
# Roles
#
#   manager    Runs /chanakya /achilles /argus inside a Claude Code session.
#           Dispatches work to registered workers. Holds the iOS project.
#           This is your primary dev machine.
#
#   worker   Headless SSH target. Accepts dispatched build + test commands
#           from one or more managers. No agents, no shell profile, no editor.
#
#   dual    Machine that runs agents AND accepts dispatches from another
#           manager. Rare — e.g. a workstation that's both your dev box and
#           a shared build host; or a single-Mac setup where you explicitly
#           want node-pick semantics against yourself.
#
# Agents-only is not a separate role — it is the manager role with no
# workers registered (i.e. nodes.json empty). Pick `manager` and decline
# the "register a worker" step at the end.
#
# Re-runnable. The wizard detects current state and only prompts for the
# delta. Going manager → manager+worker later is just "re-run, pick dual, only
# the worker-only steps execute."
#
# Usage
#
#   ./scripts/bootstrap.sh                                   # interactive
#   ./scripts/bootstrap.sh --role manager                       # skip role prompt
#   ./scripts/bootstrap.sh --role worker --id mini --yes      # fully non-interactive
#   ./scripts/bootstrap.sh --dry-run                         # preview only
#
# Flags
#
#   --role <manager|worker|dual>      Pre-select role (skips step 1 prompt)
#   --id <short-id>               Worker id for nodes.json (defaults: hostname)
#   --worker-roles <csv>           Worker role tags (default: swift-test,xcodebuild)
#   --yes                         Non-interactive: auto-answer all prompts with
#                                 sensible defaults (keep existing, install
#                                 missing). Requires --role.
#   --dry-run                     Print what would happen; change nothing.
#   --log <path>                  Override log path (default: per-run timestamped
#                                 file under ~/.dev-studio/.runtime/logs/)
#   --no-log                      Disable file logging (stdout only)
#   -h, --help                    Show this header.
#
# Exit codes
#
#   0  wizard ran to completion (whether or not every optional step applied)
#   1  preflight failure (not macOS, running as root, bad flags)
#   2  aborted by user mid-run

set -u
umask 022

# ============================================================================
# Flag parsing
# ============================================================================

ROLE=""
WORKER_ID=""
WORKER_ROLES=""
YES=0
DRY_RUN=0
LOG_PATH=""
NO_LOG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE="${2:?}"; shift 2 ;;
    --id)           WORKER_ID="${2:?}"; shift 2 ;;
    --worker-roles)  WORKER_ROLES="${2:?}"; shift 2 ;;
    --yes)          YES=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --log)          LOG_PATH="${2:?}"; shift 2 ;;
    --no-log)       NO_LOG=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'error: unknown flag: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if [ "$YES" = "1" ] && [ -z "$ROLE" ]; then
  printf 'error: --yes requires --role (manager|worker|dual) so non-interactive mode knows what to do\n' >&2
  exit 1
fi
if [ -n "$ROLE" ]; then
  case "$ROLE" in manager|worker|dual) ;;
    *) printf 'error: --role must be manager, worker, or dual (got %s)\n' "$ROLE" >&2; exit 1 ;;
  esac
fi

# ============================================================================
# ANSI helpers
# ============================================================================

if [ -t 1 ]; then
  c_cyan=$'\033[1;36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_red=$'\033[31m'; c_magenta=$'\033[35m'
  c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
  c_cyan=''; c_green=''; c_yellow=''; c_blue=''; c_red=''; c_magenta=''; c_dim=''; c_bold=''; c_reset=''
fi

step()     { printf '\n%s━━━ %s ━━━%s\n' "$c_cyan" "$*" "$c_reset"; }
substep()  { printf '\n  %s▸ %s%s\n' "$c_magenta" "$*" "$c_reset"; }
ok()       { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()     { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$*"; }
info()     { printf '  %si%s %s\n' "$c_blue" "$c_reset" "$*"; }
err()      { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
cmd_hint() { printf '  %s$ %s%s\n' "$c_dim" "$*" "$c_reset"; }
dim()      { printf '  %s%s%s\n' "$c_dim" "$*" "$c_reset"; }

# ============================================================================
# Logging — every run writes a timestamped log; stdout still shows everything
# ============================================================================

if [ "$NO_LOG" != "1" ]; then
  if [ -z "$LOG_PATH" ]; then
    LOG_DIR="$HOME/.dev-studio/.runtime/logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    LOG_PATH="$LOG_DIR/bootstrap-$(date +%Y%m%dT%H%M%S).log"
  else
    mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || true
  fi
  exec > >(tee "$LOG_PATH") 2>&1
fi

# Interactive prompt FDs. After `exec > >(tee …) 2>&1`, both stdout and stderr
# are pipes — and bash printf to a pipe is block-buffered (~4KB). A short
# prompt ("Install fswatch? [Y/n]: ") sits in the buffer and never reaches the
# screen, so `read` blocks invisibly. FD 3 (out) and FD 4 (in) bypass the tee
# pipe and write straight to the controlling terminal. Fall back to stderr/
# stdin when there is no tty (CI, ssh -T, --yes mode).
if [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; then
  exec 3>/dev/tty 4</dev/tty
else
  exec 3>&2 4<&0
fi

# Session summary accumulator — appended per step, dumped at the end.
declare -a SUMMARY_LINES
summary() { SUMMARY_LINES+=("$1"); }

# ============================================================================
# Prompt helpers (respect --yes)
#
# Prompts go to FD 3 (terminal, unbuffered). Reads come from FD 4 (terminal).
# A one-line "→ <answer>" is echoed to stderr so the tee'd log records what
# the user picked even though the prompt itself never crossed the log pipe.
# ============================================================================

ask() {
  # ask "prompt" [default] → stdout = answer
  local prompt="$1" default="${2:-}" suffix="" reply
  [ -n "$default" ] && suffix=" [$default]"
  if [ "$YES" = "1" ]; then
    printf '  %s? %s%s — using default: %s%s\n' "$c_dim" "$prompt" "$suffix" "$default" "$c_reset" >&2
    printf '%s' "$default"
    return
  fi
  printf '  ? %s%s: ' "$prompt" "$suffix" >&3
  IFS= read -r reply <&4 || reply=""
  reply="${reply:-$default}"
  printf '  %s? %s → %s%s\n' "$c_dim" "$prompt" "$reply" "$c_reset" >&2
  printf '%s' "$reply"
}

confirm() {
  # confirm "prompt" [default=y|n] — returns 0 on yes
  local prompt="$1" default="${2:-y}" suffix reply
  case "$default" in y|Y) suffix="[Y/n]" ;; *) suffix="[y/N]" ;; esac
  if [ "$YES" = "1" ]; then
    printf '  %s? %s %s — using default: %s%s\n' "$c_dim" "$prompt" "$suffix" "$default" "$c_reset" >&2
    case "$default" in y|Y) return 0 ;; *) return 1 ;; esac
  fi
  printf '  ? %s %s: ' "$prompt" "$suffix" >&3
  IFS= read -r reply <&4 || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|Yes) printf '  %s? %s → yes%s\n' "$c_dim" "$prompt" "$c_reset" >&2; return 0 ;;
    *)           printf '  %s? %s → no%s\n'  "$c_dim" "$prompt" "$c_reset" >&2; return 1 ;;
  esac
}

pause_for_user() {
  [ "$YES" = "1" ] && { dim "(non-interactive: skipping pause)"; return; }
  printf '  ↵ Press Enter when done (or Ctrl-C to abort)...' >&3
  IFS= read -r _ <&4 || true
  printf '\n' >&3
}

# dup_action <tool-label> <current-version> → echoes one of: keep | upgrade | reinstall | skip
# In --yes mode, always echoes "keep".
dup_action() {
  local label="$1" version="$2" reply outcome
  if [ "$YES" = "1" ]; then
    printf '  %s✓ %s (%s) — keeping (non-interactive)%s\n' "$c_dim" "$label" "$version" "$c_reset" >&2
    echo keep
    return
  fi
  printf '  %s◆%s %s %s(%s)%s — ' "$c_magenta" "$c_reset" "$c_bold$label$c_reset" "$c_dim" "$version" "$c_reset" >&3
  printf '[%sK%seep / [%su%s]pgrade / [%sr%s]einstall / [%ss%s]kip : ' \
    "$c_bold" "$c_reset" "$c_bold" "$c_reset" "$c_bold" "$c_reset" "$c_bold" "$c_reset" >&3
  IFS= read -r reply <&4 || reply=""
  reply="${reply:-k}"
  case "$reply" in
    k|K|keep|Keep)       outcome=keep ;;
    u|U|upgrade|Upgrade) outcome=upgrade ;;
    r|R|reinstall)       outcome=reinstall ;;
    s|S|skip|Skip)       outcome=skip ;;
    *)                   outcome=keep ;;
  esac
  printf '  %s◆ %s → %s%s\n' "$c_dim" "$label" "$outcome" "$c_reset" >&2
  echo "$outcome"
}

# ============================================================================
# Run helper — respects --dry-run
# ============================================================================

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %sDRY-RUN: %s%s\n' "$c_dim" "$*" "$c_reset"
    return 0
  fi
  "$@"
}

# ============================================================================
# Environment detection helpers
# ============================================================================

arch_name() { uname -m; }  # arm64 (Apple Silicon) | x86_64 (Intel)

brew_prefix() {
  if [ "$(arch_name)" = "arm64" ]; then echo "/opt/homebrew"; else echo "/usr/local"; fi
}

shell_rc() {
  # Pick the right rc file for the user's login shell. Falls back to both
  # .zshrc and .bash_profile if login shell can't be determined (we append
  # to whichever exists; the user's actual shell will source at least one).
  local login_shell
  login_shell=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $NF}')
  case "$login_shell" in
    */zsh)  echo "$HOME/.zshrc" ;;
    */bash) echo "$HOME/.bash_profile" ;;
    */fish) echo "$HOME/.config/fish/config.fish" ;;
    *)
      if [ -f "$HOME/.zshrc" ];   then echo "$HOME/.zshrc"
      elif [ -f "$HOME/.bash_profile" ]; then echo "$HOME/.bash_profile"
      else                           echo "$HOME/.zshrc"
      fi
      ;;
  esac
}

# Find the studio repo root. Either we're inside it (common case — user
# cloned + ran the wizard from repo), or we need to clone it somewhere.
STUDIO_REPO_DIR=""
detect_studio_repo() {
  if git -C . rev-parse --show-toplevel >/dev/null 2>&1; then
    local top basename
    top=$(git -C . rev-parse --show-toplevel)
    basename=$(basename "$top")
    if [ "$basename" = "generic-dev-studio" ]; then
      STUDIO_REPO_DIR="$top"
      return 0
    fi
  fi
  # Common clone locations — check before offering to clone fresh.
  for candidate in \
    "$HOME/Documents/v-i-s-h-a-l/github/generic-dev-studio" \
    "$HOME/projects/generic-dev-studio" \
    "$HOME/code/generic-dev-studio" \
    "$HOME/generic-dev-studio" \
    "$HOME/studio-tmp"; do
    if [ -d "$candidate/.git" ] && [ -f "$candidate/scripts/install.sh" ]; then
      STUDIO_REPO_DIR="$candidate"
      return 0
    fi
  done
  return 1
}

# ============================================================================
# Preflight
# ============================================================================

step "Preflight"

if [ "$(uname)" != "Darwin" ]; then
  err "This wizard is macOS-only (detected: $(uname))."
  err "Linux worker/worker support can land later — for now, do the manual steps in .claude/skills/studio/setup.html."
  exit 1
fi
ok "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
info "Architecture: $(arch_name) ($([ "$(arch_name)" = "arm64" ] && echo 'Apple Silicon' || echo 'Intel'))"

if [ "${EUID:-$(id -u)}" = "0" ]; then
  err "Don't run as root. The wizard will prompt for sudo where genuinely needed."
  exit 1
fi
ok "running as: $(id -un)"

if [ "$DRY_RUN" = "1" ]; then warn "DRY-RUN MODE — no mutations will be applied."; fi
if [ "$YES" = "1" ];     then warn "NON-INTERACTIVE MODE (--yes) — all prompts take their defaults."; fi
[ -n "$LOG_PATH" ] && info "Logging to: $LOG_PATH"

# Early repo detection — tells later steps whether to offer to clone.
detect_studio_repo || true
[ -n "$STUDIO_REPO_DIR" ] && ok "Studio repo found at: $STUDIO_REPO_DIR"

# ============================================================================
# Step 1 — role selection
# ============================================================================

step "1 · Role"

if [ -z "$ROLE" ]; then
  cat <<EOF

  Which role does this machine take?

    ${c_bold}manager${c_reset}   — your primary dev machine. Runs /chanakya /achilles /argus
             inside a Claude Code session. Holds your iOS project. Dispatches
             compile + test work to registered workers. (Agents-only is just
             this role with no workers registered — pick manager.)

    ${c_bold}worker${c_reset}  — a headless worker. Accepts SSH dispatches from one or more
             managers. Runs swift test / xcodebuild. No agents, no editor.
             Typical: a spare Mac mini / Mac Studio you've designated as
             a build box.

    ${c_bold}dual${c_reset}   — rare. Runs agents AND appears in another manager's worker
             registry. Use only if you know you want it (e.g. single-Mac
             setup that explicitly self-dispatches).

EOF
  ROLE=$(ask "Role" "manager")
  case "$ROLE" in manager|worker|dual) ;;
    *) err "unknown role: $ROLE"; exit 2 ;;
  esac
fi

ok "Role: $ROLE"
summary "role = $ROLE"

# ============================================================================
# Step 2 — identity
# ============================================================================

step "2 · Identity"

DETECTED_HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)

# Use the existing machine-id.sh if present in the studio repo (Phase 2.5 H).
if [ -n "$STUDIO_REPO_DIR" ] && [ -x "$STUDIO_REPO_DIR/scripts/machine-id.sh" ]; then
  MACHINE_ID=$("$STUDIO_REPO_DIR/scripts/machine-id.sh" 2>/dev/null || echo "")
  [ -n "$MACHINE_ID" ] && ok "machine-id: ${MACHINE_ID:0:12}…"
else
  MACHINE_ID=""
  warn "machine-id.sh not reachable yet — will derive after the repo is cloned (manager/dual)"
fi

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  [ -z "$WORKER_ID" ] && WORKER_ID=$(ask "Short id for this worker (in nodes.json, lock paths, event payloads)" "$DETECTED_HOST")
  ok "worker id: $WORKER_ID"
  summary "worker id = $WORKER_ID"
fi

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  if [ -z "$WORKER_ROLES" ]; then
    info "Worker role tags advertise what this machine can serve:"
    info "  swift-test         — runs 'swift test' (needs Swift toolchain — CLT minimum)"
    info "  xcodebuild         — runs full Xcode builds (needs Xcode.app + simulators)"
    info "  snapshot-canonical — generates canonical snapshot-test reference images"
    WORKER_ROLES=$(ask "Worker roles (comma-separated)" "swift-test,xcodebuild")
  fi
  ok "worker roles: $WORKER_ROLES"
  summary "worker roles = $WORKER_ROLES"
fi

# ============================================================================
# Step 3 — Homebrew + common deps
# ============================================================================

step "3 · Homebrew + packages"

# Pick deps per role.
case "$ROLE" in
  manager)
    # Manager: full dep set. yq + jq power post-2.6 YAML + event-log work;
    # fswatch powers the worker-mode file-watcher. rsync + coreutils are
    # dispatcher-side (for future #127 auto-rsync + gtimeout bounds).
    DEPS=(fswatch coreutils yq jq rsync git) ;;
  worker)
    # Worker: only what dispatched commands need. No yq/fswatch unless we
    # later ship a self-update launchd agent (see worker-manifest work).
    DEPS=(jq rsync coreutils git) ;;
  dual)
    DEPS=(fswatch coreutils yq jq rsync git) ;;
esac

if command -v brew >/dev/null 2>&1; then
  BREW_VERSION=$(brew --version 2>/dev/null | head -n 1)
  action=$(dup_action "Homebrew" "$BREW_VERSION")
  case "$action" in
    upgrade)   run brew update && run brew upgrade ;;
    reinstall) warn "Homebrew reinstall not driven by this wizard (destructive). Upgrade instead, or run the official installer manually." ;;
    keep|skip) ok "Homebrew kept" ;;
  esac
else
  warn "Homebrew not installed"
  if confirm "Install Homebrew now (runs the official installer)?"; then
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    BREW_BIN="$(brew_prefix)/bin/brew"
    [ -x "$BREW_BIN" ] && eval "$("$BREW_BIN" shellenv)"
    # Offer to persist the PATH addition to the shell rc.
    RC=$(shell_rc)
    if ! grep -qF "$(brew_prefix)/bin/brew shellenv" "$RC" 2>/dev/null; then
      if confirm "Add 'brew shellenv' to $RC so future shells find brew?"; then
        run bash -c "printf '\n# Homebrew\neval \"\$(%q shellenv)\"\n' \"$BREW_BIN\" >> \"$RC\""
        ok "Added brew shellenv to $RC"
      fi
    fi
  fi
fi

if command -v brew >/dev/null 2>&1; then
  substep "Studio packages"
  for pkg in "${DEPS[@]}"; do
    if brew list --formula 2>/dev/null | grep -qx "$pkg"; then
      VERSION=$(brew list --versions "$pkg" 2>/dev/null | awk '{print $NF}')
      action=$(dup_action "$pkg" "$VERSION")
      case "$action" in
        upgrade)   run brew upgrade "$pkg" ;;
        reinstall) run brew reinstall "$pkg" ;;
        keep|skip) ok "$pkg kept ($VERSION)" ;;
      esac
    else
      if confirm "Install $pkg?" "y"; then
        run brew install "$pkg"
      else
        warn "Skipped $pkg (some Studio features may not work without it)"
      fi
    fi
  done
else
  warn "Skipping package install — no brew available"
fi

# ============================================================================
# Step 4 — Studio repo + agent-skill install (manager / dual only)
# ============================================================================

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  step "4 · Studio repo + agent skills"

  if [ -n "$STUDIO_REPO_DIR" ]; then
    substep "Repo detected"
    ok "using existing clone: $STUDIO_REPO_DIR"
  else
    warn "Studio repo not found in the usual locations"
    CLONE_PATH=$(ask "Clone target" "$HOME/generic-dev-studio")
    if confirm "Clone generic-dev-studio into $CLONE_PATH?"; then
      run git clone https://github.com/v-i-s-h-a-l/generic-dev-studio.git "$CLONE_PATH"
      STUDIO_REPO_DIR="$CLONE_PATH"
    else
      warn "Can't proceed with manager setup without the repo. Skipping install steps."
      STUDIO_REPO_DIR=""
    fi
  fi

  if [ -n "$STUDIO_REPO_DIR" ]; then
    # Try to re-derive machine-id now if we didn't earlier.
    if [ -z "$MACHINE_ID" ] && [ -x "$STUDIO_REPO_DIR/scripts/machine-id.sh" ]; then
      MACHINE_ID=$("$STUDIO_REPO_DIR/scripts/machine-id.sh" 2>/dev/null || echo "")
      [ -n "$MACHINE_ID" ] && ok "machine-id: ${MACHINE_ID:0:12}…"
    fi

    substep "Agent skills (install.sh)"
    VERIFY_OK=1
    if [ -x "$STUDIO_REPO_DIR/scripts/verify-install.sh" ]; then
      "$STUDIO_REPO_DIR/scripts/verify-install.sh" >/dev/null 2>&1 || VERIFY_OK=0
    else
      VERIFY_OK=0
    fi

    if [ "$VERIFY_OK" = "1" ]; then
      action=$(dup_action "Agent-skill symlinks" "already installed")
      case "$action" in
        keep)      ok "install.sh result kept as-is" ;;
        upgrade|reinstall) run "$STUDIO_REPO_DIR/scripts/install.sh" ;;
        skip)      ok "skipped" ;;
      esac
    else
      info "Running install.sh..."
      run "$STUDIO_REPO_DIR/scripts/install.sh"
    fi
    summary "agent skills installed from $STUDIO_REPO_DIR"

    substep "Git hooks (contributor mode)"
    dim "Enables the architecture + privacy pre-commit hook for this repo."
    dim "You want this ON only if you plan to contribute back upstream."
    if [ -d "$STUDIO_REPO_DIR/.githooks" ] && confirm "Enable contributor git hooks in $STUDIO_REPO_DIR?" "n"; then
      ( cd "$STUDIO_REPO_DIR" && run git config core.hooksPath .githooks )
      ok "hooks path set"
    fi
  fi

  substep "Claude Code CLI"
  if command -v claude >/dev/null 2>&1; then
    CC_VERSION=$(claude --version 2>/dev/null | head -n 1 || echo "installed")
    action=$(dup_action "Claude Code CLI" "$CC_VERSION")
    case "$action" in
      upgrade|reinstall) info "Upgrade path: follow the official Claude Code update instructions (not automated here)." ;;
      keep|skip)         ok "claude kept" ;;
    esac
  else
    warn "Claude Code CLI not found on PATH"
    info "Install per the Anthropic docs (DMG / installer). Then re-run this wizard to verify."
    cmd_hint "open https://docs.claude.com/en/docs/claude-code"
  fi
fi

# ============================================================================
# Step 5 — SSH identity (manager / dual / worker — everyone needs this)
# ============================================================================

step "5 · SSH identity"

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  substep "Manager-side SSH keypair (for dispatching to workers)"
  KEY_FOUND=""
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [ -f "$k" ] && KEY_FOUND="$k" && break
  done
  if [ -n "$KEY_FOUND" ]; then
    ok "existing keypair: $KEY_FOUND"
    dim "(you can add another without removing this one; the wizard won't touch it)"
    if confirm "Generate an additional ed25519 key anyway?" "n"; then
      KEY_NAME=$(ask "Name for new key" "id_ed25519_studio")
      run ssh-keygen -t ed25519 -C "$(id -un)@studio" -f "$HOME/.ssh/$KEY_NAME" -N ""
      KEY_FOUND="$HOME/.ssh/$KEY_NAME"
    fi
  else
    warn "No SSH keypair found at ~/.ssh/id_ed25519 or ~/.ssh/id_rsa"
    if confirm "Generate an ed25519 keypair now?" "y"; then
      run ssh-keygen -t ed25519 -C "$(id -un)@studio" -f "$HOME/.ssh/id_ed25519" -N ""
      KEY_FOUND="$HOME/.ssh/id_ed25519"
    fi
  fi
  [ -n "$KEY_FOUND" ] && summary "ssh key = ${KEY_FOUND/#$HOME/~}.pub"
fi

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  substep "Worker-side: enable incoming SSH"
  RL_STATE=$(sudo -n systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print tolower($NF)}' | tr -d ' ' || echo "unknown")
  if [ "$RL_STATE" = "on" ]; then
    ok "Remote Login already enabled"
  elif [ "$RL_STATE" = "unknown" ]; then
    warn "Can't check Remote Login status without sudo."
    if confirm "Prompt for sudo to check + enable Remote Login?"; then
      if run sudo systemsetup -setremotelogin on; then
        ok "Remote Login enabled"
      else
        warn "Couldn't enable via CLI. Fallback: System Settings → General → Sharing → Remote Login"
        pause_for_user
      fi
    fi
  else
    if confirm "Enable Remote Login now (needs sudo)?" "y"; then
      if run sudo systemsetup -setremotelogin on; then
        ok "Remote Login enabled"
      else
        warn "Couldn't enable via CLI. Fallback: System Settings → General → Sharing → Remote Login"
        pause_for_user
      fi
    else
      warn "Remote Login left OFF — worker can't accept dispatches until you enable it."
    fi
  fi

  substep "Accept manager pubkey(s)"
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  touch ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys

  if [ "$YES" = "1" ]; then
    dim "Non-interactive: skipping pubkey paste prompt. Add them later:"
    cmd_hint "echo 'ssh-ed25519 …' >> ~/.ssh/authorized_keys"
  else
    # Mirror the instructions to FD 3 so they reach the terminal immediately,
    # not just the (potentially mid-buffer) tee pipe. Otherwise `cat` below
    # blocks before the user has seen what to paste.
    {
      printf '  i On your MANAGER machine, run ONE of:\n'
      printf '  $ cat ~/.ssh/id_ed25519.pub\n'
      printf '  $ cat ~/.ssh/id_rsa.pub\n'
      printf '  i Paste below (or multiple lines for multiple managers), Enter, then Ctrl-D.\n\n'
    } >&3
    info "On your MANAGER machine, run ONE of:"
    cmd_hint "cat ~/.ssh/id_ed25519.pub"
    cmd_hint "cat ~/.ssh/id_rsa.pub"
    info "Paste below (or paste multiple lines for multiple managers), press Enter, then Ctrl-D."
    echo
    PASTE=$(cat <&4 || true)
    added=0
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | tr -d '\r' | sed 's/[[:space:]]*$//')
      [ -z "$line" ] && continue
      case "$line" in ssh-*) ;; *) warn "ignored (not an ssh-* key): ${line:0:60}…"; continue ;; esac
      if grep -qF "$line" ~/.ssh/authorized_keys 2>/dev/null; then
        ok "already present: ${line:0:60}…"
      else
        printf '%s\n' "$line" >> ~/.ssh/authorized_keys
        added=$((added + 1))
        ok "added: ${line:0:60}…"
      fi
    done <<< "$PASTE"
    summary "authorized_keys: +$added new"
  fi
fi

# ============================================================================
# Step 6 — Tailscale (manager / dual / worker — all can use it)
# ============================================================================

step "6 · Tailscale"

TS_UP=0
if command -v tailscale >/dev/null 2>&1 || [ -e /Applications/Tailscale.app ]; then
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    TS_UP=1
    TS_V=$(tailscale version 2>/dev/null | head -n 1 || echo "installed")
    action=$(dup_action "Tailscale" "$TS_V")
    case "$action" in
      upgrade)   run brew upgrade --cask tailscale 2>/dev/null || run brew upgrade tailscale 2>/dev/null || warn "brew upgrade failed — update manually if needed" ;;
      reinstall) warn "Reinstall is destructive (removes tailnet state). Upgrade instead, or re-run bootstrap with reinstall awareness manually." ;;
      keep|skip) ok "Tailscale kept" ;;
    esac
  else
    warn "Tailscale present but not logged in"
    if confirm "Start Tailscale + sign in now?"; then
      cmd_hint "open -a Tailscale    # click through the GUI sign-in, or:"
      cmd_hint "sudo tailscale up"
      pause_for_user
      command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && TS_UP=1
    fi
  fi
else
  warn "Tailscale not installed"
  if confirm "Install Tailscale (free for personal use)?" "y"; then
    if command -v brew >/dev/null 2>&1; then
      run brew install --cask tailscale
    else
      info "No brew. Manual download:"
      cmd_hint "open https://tailscale.com/download/mac"
    fi
    pause_for_user
    command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && TS_UP=1
  fi
fi

# Tailscale hostname for nodes.json / registration.
TS_HOST=""
if [ "$TS_UP" = "1" ]; then
  TS_HOST=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("Self",{}).get("HostName",""))
except Exception: pass' 2>/dev/null || true)
fi
[ -z "$TS_HOST" ] && TS_HOST="$DETECTED_HOST"
ok "hostname for registration: $TS_HOST"

# Tailscale ACL scaffolding (manager only — the machine that owns the tailnet
# policy is typically the primary dev machine).
if [ "$ROLE" = "manager" ] && [ "$TS_UP" = "1" ]; then
  if confirm "Emit a recommended Tailscale ACL for a manager+worker fleet? (no auto-apply)" "n"; then
    cat <<EOF

  ${c_dim}# Recommended minimal ACL — restricts "all nodes reach all nodes".
  # Paste into your Tailscale admin console (Access Controls tab).
  # Adjust user/tag values to match your tailnet.${c_reset}

  {
    "tagOwners": {
      "tag:manager":  ["autogroup:admin"],
      "tag:worker": ["autogroup:admin"]
    },
    "acls": [
      // managers can SSH to workers
      { "action": "accept", "src": ["tag:manager"],  "dst": ["tag:worker:22"] },
      // managers can reach each other (multi-manager scenario)
      { "action": "accept", "src": ["tag:manager"],  "dst": ["tag:manager:22"] }
      // workers cannot initiate to managers — removing 'all-to-all' default
    ],
    "ssh": [
      { "action": "check", "src": ["tag:manager"], "dst": ["tag:worker"], "users": ["autogroup:nonroot"] }
    ]
  }

EOF
    info "Apply tags in the admin console to each machine (manager/worker) after pasting."
  fi
fi

# ============================================================================
# Step 7 — pmset (worker / dual — keep the box awake)
# ============================================================================

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  step "7 · Power — keep the worker awake"
  info "A worker should not sleep while idle. Recommended settings:"
  cmd_hint "sudo pmset -a sleep 0 displaysleep 10 disksleep 0"
  if confirm "Apply now (needs sudo)?" "y"; then
    run sudo pmset -a sleep 0 displaysleep 10 disksleep 0
    ok "pmset applied"
  fi

  if confirm "Is this an ALWAYS-ON machine (office studio, rack, hosted box)?" "n"; then
    info "Extra flags for always-on use:"
    cmd_hint "sudo pmset -a autorestart 1                # auto-boot after power loss"
    cmd_hint "sudo tailscaled install-system-daemon       # Tailscale as system service"
    dim "See setup.html §Always-on node for the full checklist + security considerations."
    if confirm "Apply autorestart now?" "y"; then run sudo pmset -a autorestart 1; fi
  fi
fi

# ============================================================================
# Step 8 — git config (manager / dual)
# ============================================================================

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  step "8 · Git config"
  CUR_NAME=$(git config --global user.name 2>/dev/null || echo "")
  CUR_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
  if [ -n "$CUR_NAME" ] && [ -n "$CUR_EMAIL" ]; then
    ok "user.name  = $CUR_NAME"
    ok "user.email = $CUR_EMAIL"
  else
    warn "git user.name / user.email not fully set globally"
    if [ -z "$CUR_NAME" ] && confirm "Set git user.name now?" "y"; then
      GNAME=$(ask "user.name" "$(id -un)")
      run git config --global user.name "$GNAME"
    fi
    if [ -z "$CUR_EMAIL" ] && confirm "Set git user.email now?" "y"; then
      GEMAIL=$(ask "user.email")
      [ -n "$GEMAIL" ] && run git config --global user.email "$GEMAIL"
    fi
  fi
fi

# ============================================================================
# Step 9 — Xcode / CLT (worker + manager — manager needs it for local fallback)
# ============================================================================

step "9 · Xcode toolchain"

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
  if confirm "Run 'xcode-select --install' now?" "y"; then
    run xcode-select --install || true
    info "A GUI installer should open. Wait for it to finish, then press Enter."
    pause_for_user
  fi
fi

# xcodebuild-role gets a stricter check.
case ",$WORKER_ROLES," in
  *,xcodebuild,*)
    if [ ! -e /Applications/Xcode.app ]; then
      warn "Role 'xcodebuild' requested but /Applications/Xcode.app not found."
      info "Install full Xcode.app from the App Store, or:"
      cmd_hint "open 'https://developer.apple.com/download/all/?q=Xcode'"
      info "Then:"
      cmd_hint "sudo xcode-select -s /Applications/Xcode.app"
      info "Install simulator runtimes inside Xcode → Settings → Platforms"
    else
      ok "/Applications/Xcode.app present"
      if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
        info "Verify simulator runtimes match your manager's:"
        cmd_hint "xcrun simctl list runtimes"
      fi
    fi
    ;;
esac

# ============================================================================
# Step 10 — registration emit (worker / dual) or registration prompt (manager)
# ============================================================================

step "10 · Registration"

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  CURRENT_USER=$(id -un)
  roles_json=$(printf '%s' "$WORKER_ROLES" | awk -F',' 'BEGIN{printf "["}
  {
    for (i=1;i<=NF;i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      if (length($i)==0) continue
      if (cnt++) printf ", "
      printf "\"%s\"", $i
    }
  } END{printf "]"}')

  cat <<BANNER

${c_cyan}═══ COPY-PASTE TO YOUR MANAGER MACHINE ═══${c_reset}

  ${c_dim}# File: ~/.dev-studio/.runtime/nodes.json${c_reset}
  ${c_dim}# Create if missing, or append the inner { ... } block.${c_reset}

  {
    "schema": 1,
    "nodes": [
      {
        "id": "$WORKER_ID",$([ -n "$MACHINE_ID" ] && printf '\n        "machine_id": "%s",' "$MACHINE_ID")
        "host": "$TS_HOST",
        "user": "$CURRENT_USER",
        "roles": $roles_json,
        "enabled": true
      }
    ]
  }

${c_cyan}═══ VERIFY (run on MANAGER, from the studio repo) ═══${c_reset}

  ssh -o BatchMode=yes $CURRENT_USER@$TS_HOST true && echo OK
  scripts/node-health.sh $WORKER_ID
  scripts/node-pick.sh swift-test

BANNER
  summary "registration block emitted for $WORKER_ID @ $TS_HOST"
fi

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  NODES_PATH="$HOME/.dev-studio/.runtime/nodes.json"
  mkdir -p "$(dirname "$NODES_PATH")" 2>/dev/null || true
  if [ -f "$NODES_PATH" ]; then
    ok "nodes.json exists: $NODES_PATH"
    EXISTING_COUNT=$(jq -r '.nodes | length' "$NODES_PATH" 2>/dev/null || echo "?")
    info "currently registered: $EXISTING_COUNT worker(s)"
  else
    info "nodes.json not yet created — that's fine; agents-only mode works this way."
    if confirm "Create an empty nodes.json skeleton now?" "y"; then
      run bash -c "cat > '$NODES_PATH' <<'JSON'
{ \"schema\": 1, \"nodes\": [] }
JSON"
      ok "skeleton written: $NODES_PATH"
    fi
  fi

  if [ "$ROLE" = "dual" ]; then
    info "You picked dual role — append your own entry to nodes.json if this machine should be dispatched to:"
    cmd_hint "scripts/bootstrap.sh --role worker --id $DETECTED_HOST"
    dim "(run the wizard again with --role worker to generate the entry for this same machine)"
  fi

  # ---- worker-manifest + scheduled sync (opt-in) ----
  WORKER_COUNT=0
  [ -f "$NODES_PATH" ] && WORKER_COUNT=$(jq -r '.nodes | length' "$NODES_PATH" 2>/dev/null || echo 0)

  if [ "$WORKER_COUNT" != "0" ] && [ "$WORKER_COUNT" != "?" ]; then
    substep "Worker manifest"
    if [ -n "$STUDIO_REPO_DIR" ] && [ -x "$STUDIO_REPO_DIR/scripts/init-worker-manifest.sh" ]; then
      PROJECT_GUESS=$(resolve_project 2>/dev/null || echo "")
      MANIFEST_PATH=""
      [ -n "$PROJECT_GUESS" ] && MANIFEST_PATH="$HOME/.dev-studio/$PROJECT_GUESS/worker-manifest.yaml"
      if [ -n "$MANIFEST_PATH" ] && [ -f "$MANIFEST_PATH" ]; then
        ok "manifest exists: $MANIFEST_PATH"
      else
        info "A worker-manifest declares what registered workers should have (brew packages, Xcode minimum, etc.)."
        info "It pairs with scripts/sync-worker.sh to keep workers in lock-step with this manager."
        if confirm "Create a default worker-manifest.yaml for this project?" "y"; then
          run "$STUDIO_REPO_DIR/scripts/init-worker-manifest.sh"
        fi
      fi
    fi

    substep "Scheduled worker-sync (opt-in)"
    info "A nightly launchd agent on this manager can keep registered workers in sync"
    info "with the manifest automatically — no per-update SSH needed from you."
    if confirm "Schedule worker-sync to run nightly?" "n"; then
      if [ -n "$STUDIO_REPO_DIR" ] && [ -x "$STUDIO_REPO_DIR/scripts/schedule-worker-sync.sh" ]; then
        run "$STUDIO_REPO_DIR/scripts/schedule-worker-sync.sh" --install --interval daily
      fi
    else
      dim "(skip — turn on later: scripts/configure.sh schedule on)"
    fi
  fi
fi

# ============================================================================
# Step 11 — self-test
# ============================================================================

step "11 · Self-test"

PASS=0; FAIL=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"; PASS=$((PASS + 1))
  else
    err "$label"; FAIL=$((FAIL + 1))
  fi
}

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  check "~/.claude/skills/chanakya symlinked"  test -L "$HOME/.claude/skills/chanakya"
  check "~/.claude/skills/achilles symlinked"  test -L "$HOME/.claude/skills/achilles"
  check "~/.claude/skills/argus symlinked"     test -L "$HOME/.claude/skills/argus"
  check "jq present"                           command -v jq
  check "git user.email set"                   bash -c 'test -n "$(git config --global user.email)"'
  [ -n "$STUDIO_REPO_DIR" ] && check "verify-install passes" "$STUDIO_REPO_DIR/scripts/verify-install.sh"
fi

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  check "SSH daemon accepts connections"  bash -c 'launchctl list | grep -qi ssh'
  check "jq present"                      command -v jq
  check "rsync present"                   command -v rsync
  check "Command Line Tools present"      xcode-select -p
  case ",$WORKER_ROLES," in
    *,xcodebuild,*) check "Xcode.app present"        test -e /Applications/Xcode.app ;;
    *,swift-test,*) check "swift present"            command -v swift ;;
  esac
fi

summary "self-test: $PASS passed, $FAIL failed"

# ============================================================================
# Summary + next steps
# ============================================================================

step "Summary"

for line in "${SUMMARY_LINES[@]:-}"; do
  [ -n "$line" ] && dim "  • $line"
done

echo
info "${c_bold}Next steps:${c_reset}"
case "$ROLE" in
  manager)
    info "  1. Invoke /chanakya in your iOS project to try the agent layer."
    info "  2. When you have a worker Mac: run this wizard there with --role worker."
    info "  3. Paste the worker's emitted nodes.json block into ~/.dev-studio/.runtime/nodes.json here."
    info "  4. Tweak config any time:  scripts/configure.sh"
    ;;
  worker)
    info "  1. Paste the printed nodes.json block on your manager machine."
    info "  2. From the manager, run: scripts/node-health.sh $WORKER_ID — expect 'healthy'."
    info "  3. First dispatch will be slower (cold DerivedData, first rsync)."
    ;;
  dual)
    info "  1. Re-run this wizard with --role worker to generate the self-worker entry for this machine."
    info "  2. Add the generated block to ~/.dev-studio/.runtime/nodes.json here."
    info "  3. Invoke /chanakya to try the agent layer; dispatches that pick this id run via ssh-to-localhost."
    info "  4. Tweak config any time:  scripts/configure.sh"
    ;;
esac

[ -n "$LOG_PATH" ] && dim "Log of this run: $LOG_PATH"

step "Done"
