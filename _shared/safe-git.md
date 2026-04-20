---
name: Safe Git Commit
description: Guarded wrapper around git commit that clears stale .git/index.lock when no live git process holds it.
type: reference
---

# Shared: Safe Git Commit

Guarded wrapper around `git commit` that clears stale `.git/index.lock` files when no live git process holds them. Use anywhere a skill runs a non-interactive `git commit`.

Context: parallel worktrees (Achilles + Argus), IDE git plugins, and interrupted sandbox prompts occasionally leave a zero-byte `index.lock` behind. The next commit fails with `fatal: Unable to create '.../.git/index.lock': File exists.` and strands the pipeline.

## Helper

Source this file or paste the function inline.

```bash
safe_git_commit() {
  local lock repo
  lock="$(git rev-parse --git-dir)/index.lock"
  repo="$(git rev-parse --show-toplevel)"
  if [ -e "$lock" ]; then
    if ! pgrep -f "git .* $repo" >/dev/null; then
      echo "Removing stale index.lock at $lock" >&2
      rm -f "$lock"
      # Emit event so frequency is tracked; see _shared/events.md
      local event_file
      event_file="$PROJECT_MEMORY/events/$(date -u +%Y-%m-%d).jsonl"
      mkdir -p "$(dirname "$event_file")"
      printf '%s\n' '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","agent":"'"${CALLER_SKILL:-unknown}"'","event":"stale_index_lock_removed","task":"","data":{"repo":"'"$repo"'","caller_skill":"'"${CALLER_SKILL:-unknown}"'"}}' >> "$event_file"
    fi
  fi
  git commit "$@"
}
```

Callers should export `CALLER_SKILL` (e.g. `pushTFBuild`, `achilles-merge`) before invoking so the event log attributes removals correctly. `PROJECT_MEMORY` resolves per `_shared/file-locations.md`; skip the event emit silently if unset.

## Usage

```bash
source ~/.dev-studio/.runtime/_shared/safe-git.sh   # or paste the function
CALLER_SKILL=pushTFBuild
safe_git_commit -m "$(cat <<'EOF'
Bump build number to 1234

Co-Authored-By: …
EOF
)"
```

The guard wraps the command, not the message — heredoc patterns are preserved.

## Event

See `_shared/events.md` for the `stale_index_lock_removed` row.
