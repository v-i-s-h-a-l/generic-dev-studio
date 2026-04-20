---
name: Debrief Format
description: File schema for task debriefs written to chanakya-inbox after Achilles completes.
type: reference
---

# Shared: Debrief Format

Write to `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`:

```markdown
# Debrief: <task-id> — <Title>
Completed: <YYYY-MM-DD HH:mm IST>

## Summary
<2-3 sentences on what was done>

## Commits
- <hash> — <one-line description>

## Files Changed
- <file path> — <what changed>

## Branch
- Worked on: `achilles/<task-id>`
- Merged into: `<ORIG_BRANCH>` (local, --no-ff)
- Merge commit: `<hash>`

## Build Verification
build_gate: lsp-only | full-green
build_debt_override: false         <!-- true only if --ignore-build-debt was used -->

## Testability Report
<!-- For implementation tasks -->
- **SOLID adherence:** <brief summary>
- **Accessibility IDs defined:** <path to identifier enum file, count of identifiers added>
- **Test seams exposed:** <list of protocols/interfaces created for testing>
- **Architecture pattern followed:** <pattern name, any deviations>
- **Localization:** <"N strings added via .localized, key namespace: filter.presets.*"> | <"n/a — no user-visible strings"> | <"module unlocalized — follow-up task filed: T0XX">
<!-- For test tasks -->
- **Tests written:** <count>
- **Tests passing:** <count>
- **Tests failing:** <count, with reasons>
- **Coverage areas:** <what's covered>
- **Gaps:** <what's not covered and why>

## Decisions Made
- <any deviations from the brief and why>

## Test Cases
<copy of <task-id>-tests.md>

## Performance
<!-- Include if any timing data was observed -->
- <operation>: <timing> on <device/simulator>

## Key Learnings
- <patterns, gotchas, things future sessions should know>

## Known Issues
- <unresolved — e.g., "user has not manually verified yet">

## Follow-up Tasks
- <manual-verification follow-up always present when WAIT_FOR_USER=no or on timeout>
- <new tasks discovered during implementation>
- <refactoring tasks for test utilities if patterns were duplicated>
```

After writing the debrief: update master plan — set status to `done`, record commit hashes and merge commit. `done` ≠ `verified`. Chanakya promotes to `verified` after the user processes test-manifest feedback.
