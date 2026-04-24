Open the worker-node onboarding guide in the browser.

Steps:
1. Resolve the docs path via git repo-toplevel:
   ```bash
   REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
   DOCS="$REPO_ROOT/.claude/skills/studio/node-setup.html"
   ```
2. Run `open "$DOCS"` to open the guide in the default browser.
3. Tell the user: "Worker-node setup guide opened. Path in the repo: `.claude/skills/studio/node-setup.html`."
4. If `$DOCS` does not exist, say so — do not guess a path.
