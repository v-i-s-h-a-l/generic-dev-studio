# generic-dev-studio

Multi-agent Claude Code orchestration system (Chanakya manager + Achilles worker + Argus reviewer). Per-project runtime under `~/.dev-studio/<project>/`; machine-global resources under `~/.dev-studio/.runtime/`.

## Reviews

When the user asks to review a diff (any phrasing — "review", "self-review", "check this", "any issues", or invoking `/simplify`), **read `REVIEW.md` at the repo root first** and walk its rules against the diff. Auto-fix the `block + auto-fix` tier silently; surface `ask` tier before changing; note `warn` tier either way.

Do not wait for the user to name REVIEW.md. The file is authoritative for this repo.

Skip review for single-line doc fixes. Trigger it for: any `scripts/*.sh` change, any `SKILL.md` change, any `_shared/*` change, or diffs >100 lines.

## Paths

All runtime writes go under `~/.dev-studio/**`. Scripts resolve paths via `scripts/lib-paths.sh` — never hardcode. See `_shared/file-locations.md` for canonical roots.
