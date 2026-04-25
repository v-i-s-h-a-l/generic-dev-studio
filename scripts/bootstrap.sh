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
#   ./scripts/bootstrap.sh                                   # auto-pilot — prompts for role only
#   ./scripts/bootstrap.sh --role manager                       # zero prompts
#   ./scripts/bootstrap.sh --role worker --id mini             # zero prompts
#   ./scripts/bootstrap.sh --interactive                       # legacy: prompt for everything
#   ./scripts/bootstrap.sh --dry-run                         # preview only
#
# Default UX: non-interactive auto-pilot. The wizard derives every decision
# from machine state (existing tools = keep, missing tools = install). The
# only prompt is for `role` if you didn't pass `--role`. Use `--interactive`
# to opt back into per-step prompts.
#
# Flags
#
#   --role <manager|worker|dual>  Pre-select role (skips the only mandatory prompt)
#   --id <short-id>               Worker id for nodes.json (defaults: hostname)
#   --worker-roles <csv>           Worker role tags (default: swift-test,xcodebuild)
#   --interactive                 Prompt at every step (legacy default behavior)
#   --yes                         Deprecated alias — non-interactive is now the default
#   --quick                       Quick-start: required tools + skills only, zero prompts.
#                                 Implies --role manager. Full setup: re-run without --quick.
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
# INTERACTIVE=0 is the new default: auto-decide every step from machine state.
# The wizard still prompts ONCE for role if you didn't pass --role, because
# that's the only thing it can't infer. Pass --interactive for the legacy
# prompt-at-every-step behavior.
INTERACTIVE=0
DRY_RUN=0
QUICK=0
LOG_PATH=""
NO_LOG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE="${2:?}"; shift 2 ;;
    --id)           WORKER_ID="${2:?}"; shift 2 ;;
    --worker-roles)  WORKER_ROLES="${2:?}"; shift 2 ;;
    --interactive)  INTERACTIVE=1; shift ;;
    --yes)          shift ;;  # deprecated alias — non-interactive is now the default
    --quick)        QUICK=1; ROLE="${ROLE:-manager}"; INTERACTIVE=0; shift ;;
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

if [ -n "$ROLE" ]; then
  case "$ROLE" in manager|worker|dual) ;;
    *) printf 'error: --role must be manager, worker, or dual (got %s)\n' "$ROLE" >&2; exit 1 ;;
  esac
fi
# Legacy compatibility shim: keep $YES readable for any inline test below.
# `--yes` is now a no-op (non-interactive is the default).
YES=$([ "$INTERACTIVE" = "1" ] && echo 0 || echo 1)

# Wizard mode: determines how tools are presented and installed.
#   quick       — required tools only, zero prompts, fastest path to working
#   auto        — install required + recommended, skip satisfied, minimal prompts
#   interactive — show each tool with WHY, tier badge, ? for details
if [ "$QUICK" = "1" ]; then
  WIZARD_MODE="quick"
elif [ "$INTERACTIVE" = "1" ]; then
  WIZARD_MODE="interactive"
else
  WIZARD_MODE="auto"
fi

# ============================================================================
# Shared libraries
# ============================================================================

# Script directory — used for sourcing sibling libraries.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Shared UI library: ANSI colors, output functions, prompt helpers, run().
# Source BEFORE the tee/logging setup so TTY detection sees the real stdout.
# shellcheck source=lib-ui.sh
. "$SCRIPT_DIR/lib-ui.sh"

# Tool registry engine: YAML parser, scan, install.
# shellcheck source=lib-registry.sh
. "$SCRIPT_DIR/lib-registry.sh"

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

# Stepwise primitives — per-step validate-and-recover, state file, recheck.
# shellcheck source=lib-stepwise.sh
. "$SCRIPT_DIR/lib-stepwise.sh"
stepwise_state_init

# dup_action: legacy prompt for already-installed non-registry tools.
# Used by Steps 5-10 for Tailscale, Xcode, Claude Code, etc. Registry-managed
# tools use the scan/render/install workflow instead.
# In --quick mode or --yes mode, always returns "keep" without prompting.
dup_action() {
  local label="$1" version="$2" reply outcome _ofd _ifd
  _ofd=$(_ui_out_fd); _ifd=$(_ui_in_fd)
  if [ "$YES" = "1" ] || [ "$QUICK" = "1" ]; then
    printf '  %s✓ %s (%s) — keeping (non-interactive)%s\n' "$c_dim" "$label" "$version" "$c_reset" >&2
    echo keep
    return
  fi
  printf '  %s◆%s %s %s(%s)%s — ' "$c_magenta" "$c_reset" "$c_bold$label$c_reset" "$c_dim" "$version" "$c_reset" >&"$_ofd"
  printf '[%sK%seep / [%su%s]pgrade / [%sr%s]einstall / [%ss%s]kip : ' \
    "$c_bold" "$c_reset" "$c_bold" "$c_reset" "$c_bold" "$c_reset" "$c_bold" "$c_reset" >&"$_ofd"
  IFS= read -r reply <&"$_ifd" || reply=""
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
case "$WIZARD_MODE" in
  quick)
    info "QUICK-START MODE — required tools + skills only, zero prompts."
    info "For full setup: re-run without --quick." ;;
  interactive)
    info "INTERACTIVE MODE — each tool shows WHY, tier, and alternatives. You decide." ;;
  auto)
    info "AUTO-PILOT MODE (default) — installs required + recommended, skips satisfied. Pass --interactive for per-tool control." ;;
esac
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
  # Role is the one input the wizard cannot infer from machine state, so it
  # always prompts here — even in the default non-interactive mode. (The rest
  # of the run stays auto-pilot unless --interactive is set.) Pass --role to
  # skip even this prompt.
  printf '  %s⌨  INPUT NEEDED%s  Role [manager]: ' "$c_yellow$c_bold" "$c_reset" >&3
  IFS= read -r ROLE <&4 || ROLE=""
  ROLE="${ROLE:-manager}"
  printf '  %s⌨  Role → %s%s\n' "$c_dim" "$ROLE" "$c_reset" >&2
  case "$ROLE" in manager|worker|dual) ;;
    *) err "unknown role: $ROLE (must be manager, worker, or dual)"; exit 2 ;;
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
# Step 3 — Tools (registry-driven)
#
# The tool registry (scripts/tools.yaml) is the single source of truth for
# what the studio needs. This step:
#   1. Handles Homebrew first (prerequisite for other installs)
#   2. Scans all tools for the current role
#   3. Renders the scan results (mode-dependent: quick/auto/interactive)
#   4. Installs missing brew-installable tools
# Complex tools (Tailscale, Xcode, Claude Code) appear in the scan but
# are handled procedurally in later steps.
# ============================================================================

step "3 · Tools"

# ---- Phase 1: Homebrew (must exist before we can install anything else) ----

substep "Package manager"
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew $(brew --version 2>/dev/null | head -1)"
else
  warn "Homebrew not installed"
  if [ "$QUICK" = "1" ] || confirm "Install Homebrew now (runs the official installer)?"; then
    announce "Downloading + running the official Homebrew installer (downloads CLT if missing — typically 2–10 min)"
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    BREW_BIN="$(brew_prefix)/bin/brew"
    [ -x "$BREW_BIN" ] && eval "$("$BREW_BIN" shellenv)"
    RC=$(shell_rc)
    if ! grep -qF "$(brew_prefix)/bin/brew shellenv" "$RC" 2>/dev/null; then
      if [ "$QUICK" = "1" ] || confirm "Add 'brew shellenv' to $RC so future shells find brew?"; then
        run bash -c "printf '\n# Homebrew\neval \"\$(%q shellenv)\"\n' \"$BREW_BIN\" >> \"$RC\""
        ok "Added brew shellenv to $RC"
      fi
    fi
  fi
fi

# ---- Phase 2: Scan all tools for this role ----

substep "Scanning tools for role: $ROLE"
registry_load
registry_scan "$ROLE" "$WORKER_ROLES"

# ---- Phase 3: Render scan results (mode-dependent) ----

registry_render_scan "$WIZARD_MODE"

# ---- Phase 4: Install missing brew-installable tools ----

if [ -n "$_SCAN_NEEDED" ] && command -v brew >/dev/null 2>&1; then
  substep "Installing"
  registry_install_needed "$WIZARD_MODE" || true
  summary "tools installed via registry"
elif [ -n "$_SCAN_NEEDED" ]; then
  warn "Skipping tool install — no brew available"
else
  summary "all brew tools satisfied"
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
      announce "git clone generic-dev-studio → $CLONE_PATH"
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
        upgrade|reinstall)
          announce "scripts/install.sh — re-creating agent-skill symlinks"
          run "$STUDIO_REPO_DIR/scripts/install.sh" ;;
        skip)      ok "skipped" ;;
      esac
    else
      announce "scripts/install.sh — wiring agent-skill symlinks for the first time"
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
# Quick-exit — in --quick mode, we stop after tools + skills are in place.
# The remaining steps (SSH, Tailscale, pmset, git config, Xcode, registration)
# are configuration that the user can do later via:
#   scripts/bootstrap.sh           (re-run without --quick for full setup)
#   scripts/configure.sh guide     (post-setup guided walkthrough)
# ============================================================================

if [ "$QUICK" = "1" ]; then
  step "Quick-start complete"
  ok "Required tools and agent skills are installed."
  info "For full setup (SSH, Tailscale, workers, Xcode): re-run without --quick"
  cmd_hint "scripts/bootstrap.sh"
  info "For post-setup configuration guide:"
  cmd_hint "scripts/configure.sh guide"
  [ -n "$LOG_PATH" ] && dim "Log of this run: $LOG_PATH"
  step "Done"
  exit 0
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
      announce "ssh-keygen — generating ed25519 keypair (no passphrase)"
      run ssh-keygen -t ed25519 -C "$(id -un)@studio" -f "$HOME/.ssh/$KEY_NAME" -N ""
      KEY_FOUND="$HOME/.ssh/$KEY_NAME"
    fi
  else
    warn "No SSH keypair found at ~/.ssh/id_ed25519 or ~/.ssh/id_rsa"
    if confirm "Generate an ed25519 keypair now?" "y"; then
      announce "ssh-keygen — generating ed25519 keypair (no passphrase)"
      run ssh-keygen -t ed25519 -C "$(id -un)@studio" -f "$HOME/.ssh/id_ed25519" -N ""
      KEY_FOUND="$HOME/.ssh/id_ed25519"
    fi
  fi
  [ -n "$KEY_FOUND" ] && summary "ssh key = ${KEY_FOUND/#$HOME/~}.pub"

  # Passphrase + ssh-agent + Keychain integration. A passphrase-protected
  # key works for interactive ssh (you type it, agent caches), but every
  # non-interactive dispatcher (node-health, sync-worker, node-dispatch)
  # passes -o BatchMode=yes which forbids prompting. Symptom: SSH succeeds
  # by hand, fails as "Permission denied (publickey,...)" the moment any
  # script automates it. Fix: load the key into ssh-agent with --apple-use-keychain
  # so macOS Keychain unlocks it on every login automatically.
  if [ -n "$KEY_FOUND" ]; then
    substep "Key passphrase + macOS Keychain"
    PRIV="${KEY_FOUND%.pub}"
    if ssh-keygen -y -P "" -f "$PRIV" >/dev/null 2>&1; then
      ok "key has no passphrase — non-interactive SSH works as-is"
      stepwise_record ssh_key_passphrase "ok" "no-passphrase"
    else
      warn "key $PRIV is passphrase-protected"
      info "Non-interactive dispatchers (node-health, sync-worker, node-dispatch) pass"
      info "-o BatchMode=yes which forbids prompting — they fail with 'Permission denied'"
      info "even when interactive SSH works. Loading the key into ssh-agent + Keychain"
      info "fixes this for all future sessions."
      cmd_hint "ssh-add --apple-use-keychain $PRIV"
      if confirm "Run ssh-add --apple-use-keychain now (will prompt for the passphrase once)?" "y"; then
        # ssh-add prompts on its own controlling terminal — no FD plumbing needed.
        if ssh-add --apple-use-keychain "$PRIV" </dev/tty; then
          ok "key loaded; macOS Keychain will unlock it on every login"
          stepwise_record ssh_key_passphrase "ok" "loaded-via-keychain"
        else
          warn "ssh-add failed — re-run manually: ssh-add --apple-use-keychain $PRIV"
          stepwise_record ssh_key_passphrase "fail" "ssh-add-failed"
        fi
      else
        warn "skipped — non-interactive SSH will fail until you run ssh-add manually"
        stepwise_record ssh_key_passphrase "skipped:user"
      fi
      # Persist the auto-load behavior so a fresh shell / reboot still works
      # without manual ssh-add. The block is idempotent — only appended if
      # absent. Modern macOS man ssh_config explicitly recommends UseKeychain
      # alongside AddKeysToAgent for this exact use case.
      SSH_CONFIG="$HOME/.ssh/config"
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"
      if ! grep -qE '^[[:space:]]*UseKeychain[[:space:]]+yes' "$SSH_CONFIG" 2>/dev/null; then
        if confirm "Append AddKeysToAgent + UseKeychain to ~/.ssh/config so this persists across reboots?" "y"; then
          {
            printf '\n# Added by generic-dev-studio bootstrap (#176): persist key in macOS Keychain\n'
            printf 'Host *\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile %s\n' "$PRIV"
          } >> "$SSH_CONFIG"
          ok "appended Host * block to $SSH_CONFIG"
          stepwise_record ssh_config_keychain "ok"
        fi
      else
        ok "~/.ssh/config already configures UseKeychain"
        stepwise_record ssh_config_keychain "ok" "already-present"
      fi
    fi
  fi
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
    stepwise_record ssh_pubkey "skipped:non-interactive"
  else
    # Per-step validate-and-retry. Each pasted line is parsed by ssh-keygen;
    # we surface the fingerprint + comment back for confirmation BEFORE writing
    # to authorized_keys. A mistyped key never gets accepted silently.
    pubkey_attempt=0
    pubkey_added=0
    pubkey_rejected=0
    while :; do
      pubkey_attempt=$((pubkey_attempt + 1))
      {
        printf '\n  i On your MANAGER machine, run ONE of:\n'
        printf '  $ cat ~/.ssh/id_ed25519.pub\n'
        printf '  $ cat ~/.ssh/id_rsa.pub\n'
        printf '  i Paste below (one or more lines), press Enter, then Ctrl-D.\n'
        printf '  i Each line is parsed before write — fingerprint shown for confirmation.\n\n'
      } >&3
      PASTE=$(cat <&4 || true)
      attempt_added=0
      attempt_rejected=0
      while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r' | sed 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        if parsed=$(stepwise_validate_pubkey "$line" 2>/dev/null); then
          info "parsed: $parsed"
          if grep -qF "$line" ~/.ssh/authorized_keys 2>/dev/null; then
            ok "already in authorized_keys — skipping"
            continue
          fi
          # Confirm before writing — mistypes that happen to be valid keys
          # (e.g. you pasted the wrong machine's key) still get caught here.
          if confirm "Append this key to ~/.ssh/authorized_keys?" "y"; then
            printf '%s\n' "$line" >> ~/.ssh/authorized_keys
            attempt_added=$((attempt_added + 1))
            ok "appended"
          else
            warn "skipped this key on user request"
          fi
        else
          err "rejected (not a valid pubkey line): ${line:0:60}…"
          attempt_rejected=$((attempt_rejected + 1))
        fi
      done <<< "$PASTE"
      pubkey_added=$((pubkey_added + attempt_added))
      pubkey_rejected=$((pubkey_rejected + attempt_rejected))
      if [ "$pubkey_added" -gt 0 ]; then
        ok "$pubkey_added key(s) accepted"
        stepwise_record ssh_pubkey "ok" "added=$pubkey_added"
        break
      fi
      # Nothing accepted yet — invoke the recovery menu.
      reason="$attempt_rejected line(s) rejected, 0 keys accepted (attempt $pubkey_attempt)"
      [ "$attempt_rejected" = "0" ] && reason="empty paste; no keys captured (attempt $pubkey_attempt)"
      action=$(stepwise_recover_menu ssh_pubkey "$reason")
      case "$action" in
        retry) continue ;;
        fix)
          info "Opening ~/.ssh/authorized_keys in \$EDITOR (${EDITOR:-vi}) — paste keys there, save, return."
          "${EDITOR:-vi}" "$HOME/.ssh/authorized_keys"
          # Don't auto-mark ok — we don't know what they did. Re-validate.
          if [ -s "$HOME/.ssh/authorized_keys" ]; then
            ok "authorized_keys is non-empty after edit"
            stepwise_record ssh_pubkey "ok" "user-edited"
          else
            warn "authorized_keys is still empty"
            stepwise_record ssh_pubkey "skipped:empty-after-edit"
          fi
          break ;;
        skip)
          warn "skipping pubkey step — worker won't accept manager dispatches until a key is added"
          info "later: ssh-copy-id <user>@<this-host>.local  (from each manager)"
          stepwise_record ssh_pubkey "skipped:user"
          break ;;
        abort)
          err "aborted by user — state saved, resume with: scripts/bootstrap.sh --resume"
          stepwise_record ssh_pubkey "aborted"
          exit 2 ;;
      esac
      [ "$pubkey_attempt" -ge 3 ] && {
        warn "3 attempts exhausted — leaving authorized_keys as-is"
        stepwise_record ssh_pubkey "skipped:retry-exhausted"
        break
      }
    done
    summary "authorized_keys: +$pubkey_added new (rejected: $pubkey_rejected)"
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
      announce "brew install --cask tailscale (~100MB download)"
      run brew install --cask tailscale
    else
      info "No brew. Manual download:"
      cmd_hint "open https://tailscale.com/download/mac"
    fi
    pause_for_user
    command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && TS_UP=1
  fi
fi

# Hostname for nodes.json registration. The captured value MUST resolve from
# the manager — past wizards captured `hostname -s` (no .local) which fails
# on Bonjour-only LANs. stepwise_resolve_host probes Tailscale magic-DNS
# first, then bare, then <bare>.local; returns the first form that resolves.
if RESOLVED_HOST=$(stepwise_resolve_host "$DETECTED_HOST"); then
  TS_HOST="$RESOLVED_HOST"
  if [ "$TS_HOST" = "$DETECTED_HOST" ]; then
    ok "hostname for registration: $TS_HOST (resolved as-is)"
  else
    ok "hostname for registration: $TS_HOST (auto-corrected from \"$DETECTED_HOST\")"
  fi
  stepwise_record hostname "ok" "$TS_HOST"
else
  TS_HOST="$DETECTED_HOST"
  warn "hostname \"$TS_HOST\" did not resolve from this machine."
  info "It may still resolve from your manager (Tailscale, /etc/hosts, etc.)."
  info "If not: try \`scutil --set HostName <reachable-name>\` or use the IP."
  stepwise_record hostname "fail" "did-not-resolve:$TS_HOST"
fi

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

# xcodebuild-role gets a stricter check + an interactive recovery menu when
# Xcode is missing. Rather than print 4 lines of advice and continue (the
# old behavior — you find out it never worked when you try to dispatch),
# we ask the user how they want to proceed RIGHT NOW.
case ",$WORKER_ROLES," in
  *,xcodebuild,*)
    if [ -e /Applications/Xcode.app ]; then
      ok "/Applications/Xcode.app present"
      stepwise_record xcode_app "ok"
      if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
        info "Verify simulator runtimes match your manager's:"
        cmd_hint "xcrun simctl list runtimes"
      fi
    else
      err "Role 'xcodebuild' requested but /Applications/Xcode.app not found."
      while :; do
        {
          printf '\n  How do you want to handle this?\n\n'
          printf '    [1] Open the App Store now (sign in, click "Get" on Xcode; ~10 GB).\n'
          printf '    [2] Install via the xcodes CLI (faster; ~20 min download).\n'
          printf '    [3] Drop xcodebuild from this worker — keep swift-test only.\n'
          printf '    [4] Skip — install Xcode later, then run scripts/configure.sh recheck.\n\n'
          printf '  \033[1;33m⌨  CHOOSE\033[0m  [1/2/3/4]: '
        } >&3
        IFS= read -r reply <&4 || reply="4"
        case "$reply" in
          1)
            run open -a "App Store"
            info "After Xcode finishes installing, accept the license:"
            cmd_hint "sudo xcodebuild -license accept"
            info "Then re-run validation: scripts/configure.sh recheck"
            stepwise_record xcode_app "skipped:installing-via-app-store"
            break ;;
          2)
            if ! command -v xcodes >/dev/null 2>&1; then
              if confirm "xcodes CLI not installed. Install via brew?" "y"; then
                run brew install xcodes || { warn "brew install xcodes failed"; }
              fi
            fi
            if command -v xcodes >/dev/null 2>&1; then
              announce "xcodes install --latest (downloads + extracts; ~20 min on a fast link)"
              if run xcodes install --latest; then
                ok "Xcode installed via xcodes"
                stepwise_record xcode_app "ok"
              else
                warn "xcodes install failed — recheck after manual fix"
                stepwise_record xcode_app "fail" "xcodes-install-failed"
              fi
            fi
            break ;;
          3)
            # Drop xcodebuild from the role list. The manifest still records
            # the worker's intent in case the user re-enables later via recheck.
            new_roles=$(printf '%s' "$WORKER_ROLES" | awk -F, -v OFS=, '{
              out=""
              for (i=1;i<=NF;i++) if ($i != "xcodebuild") out = (out=="" ? $i : out","$i)
              print out
            }')
            WORKER_ROLES="$new_roles"
            ok "this worker scoped to: ${WORKER_ROLES:-(empty — add roles via configure.sh)}"
            info "Re-add xcodebuild later: scripts/configure.sh recheck (after installing Xcode)"
            stepwise_record xcode_app "skipped:role-scoped-down"
            break ;;
          4|"")
            warn "skipped — xcodebuild dispatches will fail until Xcode is installed."
            info "When Xcode is in /Applications, re-validate:"
            cmd_hint "scripts/configure.sh recheck"
            stepwise_record xcode_app "skipped:user"
            break ;;
          *) warn "pick 1, 2, 3, or 4"; continue ;;
        esac
      done
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

  ${c_dim}# If the manager's user differs from this worker's user (\"$CURRENT_USER\"),${c_reset}
  ${c_dim}# that's fine — Achilles' source-sync (lib-source-sync.sh / #127) mirrors${c_reset}
  ${c_dim}# every dispatched path under the REMOTE \$HOME, not the manager's absolute${c_reset}
  ${c_dim}# path. The two machines stay decoupled in user namespace.${c_reset}

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
    info "A worker-manifest declares what each registered worker should have (brew packages, Xcode minimum, etc.)."
    info "It pairs with scripts/sync-worker.sh to keep workers in lock-step with this manager."
    info "Create one from inside your iOS project repo (where 'git rev-parse --show-toplevel' resolves the project name):"
    cmd_hint "cd ~/path/to/your-ios-project && $STUDIO_REPO_DIR/scripts/init-worker-manifest.sh"

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
declare -a FAILED_STEPS

# check_step records every result to bootstrap-state.json so configure.sh
# recheck has a baseline. On fail, it accumulates the step-id; the post-loop
# block below presents one combined recovery menu so the user isn't asked
# four times in a row for related failures.
check_step() {
  local id="$1" label="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    ok "$label"; PASS=$((PASS + 1))
    stepwise_record "$id" "ok"
  else
    err "$label"; FAIL=$((FAIL + 1))
    FAILED_STEPS+=("$id:$label")
    stepwise_record "$id" "fail"
  fi
}

if [ "$ROLE" = "manager" ] || [ "$ROLE" = "dual" ]; then
  check_step skill_chanakya  "~/.claude/skills/chanakya symlinked"  test -L "$HOME/.claude/skills/chanakya"
  check_step skill_achilles  "~/.claude/skills/achilles symlinked"  test -L "$HOME/.claude/skills/achilles"
  check_step skill_argus     "~/.claude/skills/argus symlinked"     test -L "$HOME/.claude/skills/argus"
  check_step jq              "jq present"                           command -v jq
  check_step git_user_email  "git user.email set"                   bash -c 'test -n "$(git config --global user.email)"'
  [ -n "$STUDIO_REPO_DIR" ] && check_step verify_install "verify-install passes" "$STUDIO_REPO_DIR/scripts/verify-install.sh"
fi

if [ "$ROLE" = "worker" ] || [ "$ROLE" = "dual" ]; then
  check_step sshd  "SSH daemon accepts connections"  bash -c 'launchctl list | grep -qi ssh'
  check_step jq    "jq present"                      command -v jq
  check_step rsync "rsync present"                   command -v rsync
  check_step clt   "Command Line Tools present"      xcode-select -p
  case ",$WORKER_ROLES," in
    *,xcodebuild,*) check_step xcode_app "Xcode.app present"  test -e /Applications/Xcode.app ;;
    *,swift-test,*) check_step swift     "swift present"      command -v swift ;;
  esac
fi

summary "self-test: $PASS passed, $FAIL failed"

# Inline recovery for any failed step. We don't ABORT here — the install ran
# to completion; we just tell the user how to recover and where to validate.
if [ "$FAIL" -gt 0 ]; then
  printf '\n  %s%d step(s) failed — recovery hints:%s\n\n' "$c_yellow" "$FAIL" "$c_reset"
  for entry in "${FAILED_STEPS[@]:-}"; do
    id="${entry%%:*}"
    label="${entry#*:}"
    case "$id" in
      skill_chanakya|skill_achilles|skill_argus|verify_install)
        printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$label"
        printf '       fix: cd %s && scripts/install.sh\n' "${STUDIO_REPO_DIR:-<studio-repo>}"
        ;;
      jq|rsync) printf '  %s✗%s %s\n       fix: brew install %s\n' "$c_red" "$c_reset" "$label" "$id" ;;
      git_user_email)
        printf '  %s✗%s %s\n       fix: git config --global user.email "you@example.com"\n' "$c_red" "$c_reset" "$label" ;;
      sshd)
        printf '  %s✗%s %s\n       fix: System Settings → General → Sharing → Remote Login (or sudo systemsetup -setremotelogin on)\n' "$c_red" "$c_reset" "$label" ;;
      clt)
        printf '  %s✗%s %s\n       fix: xcode-select --install\n' "$c_red" "$c_reset" "$label" ;;
      xcode_app)
        printf '  %s✗%s %s\n       fix: install Xcode.app to /Applications (App Store / xcodes / .xip)\n' "$c_red" "$c_reset" "$label"
        printf '       then: scripts/configure.sh recheck\n' ;;
      swift)
        printf '  %s✗%s %s\n       fix: install Command Line Tools (xcode-select --install) or full Xcode\n' "$c_red" "$c_reset" "$label" ;;
      *)
        printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$label" ;;
    esac
  done
  printf '\n  After fixing: %sscripts/configure.sh recheck%s — re-validates everything; reports newly-passing steps.\n\n' "$c_bold" "$c_reset"
fi

# Persist role + worker_roles + machine_id into the state file so recheck
# from any future session knows what to validate without re-prompting.
stepwise_state="$(stepwise_state_path)"
if [ -f "$stepwise_state" ] && command -v jq >/dev/null 2>&1; then
  wroles_json=$(printf '%s' "$WORKER_ROLES" | jq -R 'split(",") | map(select(length>0))')
  jq --arg role "$ROLE" --arg mid "$MACHINE_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson roles "${wroles_json:-[]}" \
     '. + {role: $role, machine_id: $mid, worker_roles: $roles, last_run: $ts}' \
     "$stepwise_state" > "$stepwise_state.tmp" 2>/dev/null && mv "$stepwise_state.tmp" "$stepwise_state"
fi

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
