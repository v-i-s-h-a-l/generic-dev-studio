---
description: Onboard the current machine via scripts/bootstrap.sh. No args → interactive manager. Flags: --manager, --worker, --dual, --interactive, --dry-run, --help.
allowed-tools: [Bash]
argument-hint: "[--manager|--worker|--dual] [--id <id>] [--roles a,b] [--interactive] [--dry-run] [--help]"
---

# Studio setup

Thin dispatcher in front of `scripts/bootstrap.sh`. Onboards **the current machine** (the box this Claude Code session is running on) as manager, worker, or dual. To onboard a different machine, SSH there first.

## Args

Parse `$ARGUMENTS`:

| Invocation | Resolves to |
|---|---|
| (empty) | `scripts/bootstrap.sh --role manager` (interactive — *no* `--yes`) |
| `--manager` | `scripts/bootstrap.sh --role manager --yes` |
| `--worker [--id <id>] [--roles a,b]` | `scripts/bootstrap.sh --role worker --yes [--id …] [--worker-roles …]` |
| `--dual [--id <id>] [--roles a,b]` | `scripts/bootstrap.sh --role dual --yes [--id …] [--worker-roles …]` |
| `--help` or `-h` | Open `setup.html` in browser, print usage summary, exit |

Modifiers (apply on top of any role flag):
- `--interactive` — drop the `--yes`; bootstrap will prompt.
- `--dry-run` — pass through to bootstrap; previews only.

Conflicts: more than one role flag → error. `--interactive` with no role → ignored (no-args is already interactive).

## Steps

### 1. Resolve repo + parse

```bash
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "error: not in a git repo — clone generic-dev-studio first" >&2; exit 1; }
```

### 2. `--help` / `-h` short-circuit

```bash
DOCS="$REPO_ROOT/.claude/skills/studio/setup.html"
[ -f "$DOCS" ] && open "$DOCS"
```

Then print:

```
/studio-setup                   onboard this machine as manager (interactive)
/studio-setup --manager         non-interactive manager
/studio-setup --worker          non-interactive worker (id defaults to hostname)
/studio-setup --worker --id X   override worker id
/studio-setup --dual            both roles on one box (rare)
/studio-setup --interactive     drop --yes when used with a role flag
/studio-setup --dry-run         preview without changing anything
/studio-setup --help            this message + open the setup guide
```

Tell the user: "Setup guide opened. To run the wizard: `/studio-setup --manager` (or `--worker`, `--dual`)." Stop.

### 3. Build the bootstrap command

Translate the parsed args:

| Slash flag | Bootstrap flag |
|---|---|
| `--manager` | `--role manager --yes` |
| `--worker`  | `--role worker --yes`  |
| `--dual`    | `--role dual --yes`    |
| `--id X`    | `--id X` |
| `--roles a,b` | `--worker-roles a,b` |
| `--interactive` | strip `--yes` |
| `--dry-run` | `--dry-run` |
| (no role flag) | `--role manager` (interactive — no `--yes`) |

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
  /studio nodes               # see registered workers and fleet health
  /studio nodes add           # register a worker (e.g. your Mac mini)
  scripts/configure.sh        # post-install tweaks
```

If exit was non-zero, just surface the error and the bootstrap log path (bootstrap.sh prints it).

## Out of scope

- Onboarding remote machines over SSH — that requires running this command (or `scripts/bootstrap.sh`) on the remote machine itself.
- Day-2 fleet management (registering workers, syncing, health checks). Use `/studio nodes`.
- Editing the worker manifest. Use `scripts/configure.sh manifest`.
