---
description: Onboard the current machine via scripts/bootstrap.sh. Auto-pilot by default — only prompts for role if not given. Flags: --manager, --worker, --dual, --interactive, --dry-run, --help.
allowed-tools: [Bash]
argument-hint: "[--manager|--worker|--dual] [--id <id>] [--roles a,b] [--interactive] [--dry-run] [--help]"
---

# Studio setup

Thin dispatcher in front of `scripts/bootstrap.sh`. Onboards **the current machine** (the box this Claude Code session is running on) as manager, worker, or dual. To onboard a different machine, SSH there first.

The bootstrap wizard is **auto-pilot by default** — it derives every decision from machine state. The only mandatory user input is `role`, and even that is skipped if you pass a role flag below. Pass `--interactive` to opt back into per-step prompts.

## Args

Parse `$ARGUMENTS`:

| Invocation | Resolves to |
|---|---|
| (empty) | `scripts/bootstrap.sh` — prompts for role only, then auto-pilots |
| `--manager` | `scripts/bootstrap.sh --role manager` (zero prompts) |
| `--worker [--id <id>] [--roles a,b]` | `scripts/bootstrap.sh --role worker [--id …] [--worker-roles …]` (zero prompts) |
| `--dual [--id <id>] [--roles a,b]` | `scripts/bootstrap.sh --role dual [--id …] [--worker-roles …]` (zero prompts) |
| `--help` or `-h` | Print usage summary, exit |

Modifiers (apply on top of any role flag):
- `--interactive` — pass through; bootstrap prompts at every step.
- `--dry-run` — pass through to bootstrap; previews only.

Conflicts: more than one role flag → error.

## Steps

### 1. Resolve repo + parse

```bash
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "error: not in a git repo — clone generic-dev-studio first" >&2; exit 1; }
```

### 2. `--help` / `-h` short-circuit

```bash
DOCS="$REPO_ROOT/core/v2/skills/dev-studio/SKILL.md"
[ -f "$DOCS" ] && open "$DOCS"
```

Then print:

```
/studio-setup                   auto-pilot — prompts for role only
/studio-setup --manager         zero-prompt manager onboarding
/studio-setup --worker          zero-prompt worker (id defaults to hostname)
/studio-setup --worker --id X   override worker id
/studio-setup --dual            both roles on one box (rare)
/studio-setup --interactive     prompt at every step (legacy)
/studio-setup --dry-run         preview without changing anything
/studio-setup --help            this message + open the v2 router source
```

Tell the user: "Studio v2 router opened. To run the wizard: `/studio-setup --manager` (or `--worker`, `--dual`)." Stop.

### 3. Build the bootstrap command

Translate the parsed args:

| Slash flag | Bootstrap flag |
|---|---|
| `--manager` | `--role manager` |
| `--worker`  | `--role worker`  |
| `--dual`    | `--role dual`    |
| `--id X`    | `--id X` |
| `--roles a,b` | `--worker-roles a,b` |
| `--interactive` | `--interactive` |
| `--dry-run` | `--dry-run` |
| (no role flag) | (no flag — bootstrap auto-pilots, prompting only for role) |

### 4. Footgun guard

Before running, print:

```
About to bootstrap THIS machine ($(hostname)) as role: <role>.
This is a local install — it does not SSH anywhere.
To onboard a different machine, run /studio-setup there.
```

No confirmation prompt. If the user typed the flag, proceed.

### 5. Run

```bash
exec "$REPO_ROOT/scripts/bootstrap.sh" <translated-flags>
```

(Use `exec` so bootstrap.sh's exit code propagates.)

### 6. After exit

If exit was 0, print:

```
Bootstrap complete. Next steps:
  scripts/worker-status.sh     # see registered workers and fleet health
  /studio-setup --worker       # run on another machine to register a worker
  scripts/configure.sh        # post-install tweaks
```

If exit was non-zero, just surface the error and the bootstrap log path (bootstrap.sh prints it).

## Out of scope

- Onboarding remote machines over SSH — that requires running this command (or `scripts/bootstrap.sh`) on the remote machine itself.
- Day-2 fleet management beyond status and bootstrap-time registration.
- Editing the worker manifest. Use `scripts/configure.sh manifest`.
