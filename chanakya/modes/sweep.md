---
name: Chanakya Sweep
description: Inbox-sweep-only invocation. Runs the pre-dispatch Step 0 (Steps 0A–0G defined in modes/inbox-sweep.md) and exits. No status table, no dashboard render, no task-list rendering. Intended for smoke-tests, validation passes, and pre-dispatch warm-ups where the full status view is unnecessary overhead.
type: mode-pack
snapshots: []
budget_tokens: 500
reads: []
writes: []
---

# Mode: Sweep (`/chanakya sweep`)

Run the inbox sweep and exit. Nothing else.

Step 0 (the inbox sweep) is the pre-dispatch step that fires before every mode — its full procedure lives in `modes/inbox-sweep.md` (Steps 0A–0G: regular task debriefs, manual-build-check debriefs, release debriefs, App Store watcher, threshold actions, stale-artifact janitor, event log, feedback reminders, blind-spot detection, studio-feedback ingestion). That already ran before this mode pack was invoked.

**This mode pack does nothing beyond what Step 0 already did.** After Step 0 completes:

1. Report the sweep summary — what got processed, what got minted, what got flagged. Same format as the sweep-summary portion of `/chanakya status`, but without the trailing status table / dashboard / blockers / release rows.
2. Exit.

Skip: rendering the master plan, reading `plans/rounds/*.yaml`, computing blockers, displaying debt counters beyond the changes this sweep made, test-flow round status, release status, push-queue surface.

**When to use:**
- Smoke-test after changing sweep logic — validate Step 0 without the noise of full status rendering.
- Pre-dispatch warm-up before a batch of Achilles work — clear the inbox, then hand-dispatch.
- Headless validation in scripts where you only care that the sweep ran and didn't flag anything.

For the full project overview, use `/chanakya` or `/chanakya status` instead.
