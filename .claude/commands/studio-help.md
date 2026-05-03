Open the Generic Dev Studio v2 router source in the editor/browser.

Steps:
1. Resolve the docs path via git repo-toplevel:
   ```bash
   REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
   DOCS="$REPO_ROOT/core/v2/skills/dev-studio/SKILL.md"
   ```
2. Run `open "$DOCS"` to open the router source in the default app.
3. Tell the user: "Studio v2 router opened. Path in the repo: `core/v2/skills/dev-studio/SKILL.md`."
4. If `$DOCS` does not exist, say so — do not guess a path.
