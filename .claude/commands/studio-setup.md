Open the Studio machine-setup guide in the browser.

Covers onboarding any machine — manager (primary, runs agents), worker (headless worker), or dual — via the unified `scripts/bootstrap.sh` wizard.

Steps:
1. Resolve the docs path via git repo-toplevel:
   ```bash
   REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
   DOCS="$REPO_ROOT/.claude/skills/studio/setup.html"
   ```
2. Run `open "$DOCS"` to open the guide in the default browser.
3. Tell the user: "Studio setup guide opened. Path in the repo: `.claude/skills/studio/setup.html`. Run the wizard with `scripts/bootstrap.sh` on any machine you want to onboard."
4. If `$DOCS` does not exist, say so — do not guess a path.
