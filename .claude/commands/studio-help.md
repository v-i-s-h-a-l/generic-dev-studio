Open the Generic Dev Studio documentation page in the browser.

Steps:
1. Resolve the docs path via git repo-toplevel:
   ```bash
   REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
   DOCS="$REPO_ROOT/.claude/skills/studio/docs.html"
   ```
2. Run `open "$DOCS"` to open the docs in the default browser.
3. Tell the user: "Studio docs opened. Path in the repo: `.claude/skills/studio/docs.html`."
4. If `$DOCS` does not exist, say so — do not guess a path.
