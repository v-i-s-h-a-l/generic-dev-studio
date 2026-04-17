# Shared: Argus Review Rules (v1)

## Scope Caps

Numeric limits enforced on every review. Emit `review_scoped` event whenever a cap is triggered.

| Cap | Limit | How to apply |
|---|---|---|
| Cross-file neighbor files (Check 1) | 10 files max | Most-referenced symbols first, then alphabetical. |
| Lines per neighbor file | 50 lines max | `head -50` or targeted grep window. Load whole file if ≤50 lines. |
| Max diff size loaded | 500 lines | Sort changed files by change size desc; load top 500 lines; note remainder. |
| XS-trivial skip | diff <20 lines AND single file AND task XS | Skip Argus entirely; emit `review_scoped` with `cap: xs_skip`. |

Argus's narrow v1 review catalog. These are the checks Achilles cannot do well from its single-worktree view. SOLID, localization, and accessibility checks belong to Achilles — do not duplicate them here.

---

## Verdict taxonomy

| Verdict | Meaning | Action |
|---|---|---|
| **Block** | Cannot merge safely | Argus returns `blocked`; Achilles loops back to revise |
| **Flag** | Suboptimal; mergeable | Argus records findings in `review_<task-id>.md`; merge proceeds |
| **Approve** | Nothing notable | Silent; merge proceeds |

---

## Week 1 Rollout Posture

**Only hard checks are blocks in week 1.** Everything else is flag-only, regardless of severity.

Hard checks (block from day 1):
- Compile failure / test failure on M/L
- Secrets in diff
- Base-branch staleness

All other checks (diff anomalies, edge-case gaps, test adequacy, regression risk): **flag only in week 1.** Promote to block when you've observed signal from real runs.

To promote a flag check to block: edit the `Block?` column in the check tables below from `week1: flag` to `yes`.

---

## Check 1 — Cross-File Regression Risk

**Goal:** identify files the diff touches that other features depend on. A single-worktree worker can't see cross-feature call graphs.

**Procedure:**

1. Extract all changed Swift files from the diff.
2. For each changed file, scan for:
   - Types/protocols/functions marked `public` or `open`
   - Protocol conformances added or removed
   - Initializer signatures changed (parameters added/removed/retyped)
   - Property observers (`willSet`/`didSet`) on shared-state properties
3. For each detected change, grep the full repo (not just the worktree) for callers:
   ```bash
   git -C <repo-root> grep -rn "<symbol>" -- '*.swift'
   ```
4. Flag callers in files NOT in the diff that would be affected by the signature change.

**Verdict:**
- Callers exist but are untouched and the change is backward-compatible → **approve** (or flag with low severity)
- Callers exist, change is breaking (signature incompatible) → **flag** (week 1) / block (later)
- No callers found → approve

| Check | Block? | Notes |
|---|---|---|
| Breaking public API change with unchecked callers | week1: flag | Promote to block after week 1 validation |

---

## Check 2 — Edge-Case Generation

**Goal:** actively enumerate edge cases the implementation may not handle, then verify test coverage.

**Procedure:**

1. For each changed function or method in the diff, enumerate candidate edge cases:
   - **Negative / boundary inputs:** empty strings, nil optionals, negative numbers, zero, Int.max/min, empty arrays, single-element collections
   - **Concurrency hazards:** shared mutable state accessed from multiple actors, `@MainActor`-isolated code called from background, `Task` cancellation paths
   - **Failure paths:** network errors, disk full, permission denied, decoding failures, timeout
   - **State machine edges:** invalid state transitions, double-invocation, invocation after teardown/deinit
   - **Empty states:** views rendered with no data, empty search results, zero-item lists

2. For each enumerated edge case, grep the test files (scope: task's test targets) for a test covering that case.

3. Produce a table:

```
| Edge case                | Covered? | Test name (if yes)         |
|--------------------------|----------|----------------------------|
| Empty input string       | yes      | testApply_emptyInput_...   |
| Nil optional parameter   | no       | —                          |
| Cancellation mid-flight  | no       | —                          |
```

**Verdict:** Uncovered cases → **flag** (include table in review file for Chanakya to auto-file follow-ups).

| Check | Block? | Notes |
|---|---|---|
| Uncovered edge cases | week1: flag | Never blocks — always flag |

---

## Check 3 — Test Adequacy

**Goal:** verify that tests exercise changed code paths, not just touch them.

**Procedure:**

1. For each changed function in the diff, identify which test(s) invoke it.
2. Evaluate **assertion density**: does each test `#expect` or `XCTAssert` an observable outcome, or does it just call the function without asserting?
3. Evaluate **path coverage**: does the test reach the changed lines, or does it call a wrapper that bypasses them?
4. Flag tests that call changed functions but assert on unrelated outcomes (marker: false sense of coverage).

**Verdict:** Inadequate tests → **flag** with specific test names and what's missing.

| Check | Block? | Notes |
|---|---|---|
| Tests with no assertions on changed paths | week1: flag | |
| Tests that don't reach changed lines | week1: flag | |

---

## Check 4 — Diff Anomalies

Quick scan for things that should never ship.

| Anomaly | Detection pattern | Block? |
|---|---|---|
| Debug prints | `print(`, `NSLog(`, `debugPrint(`, `dump(` in non-test files | week1: flag |
| Commented-out code blocks | `// <code>` spanning ≥3 consecutive lines | week1: flag |
| Hardcoded magic values | Bare numeric literals ≠ 0/1 in business logic (not constants, not tests) | week1: flag |
| Unusual diff size | Single commit >500 lines changed without a clear bulk-edit reason | week1: flag |
| Scope creep | Files changed outside the brief's stated scope (compare diff file list to `## Files to Modify` in brief) | week1: flag |

**Procedure for scope creep:**
1. Read the brief's `## Files to Modify` / `## Acceptance Criteria` sections.
2. Diff the set of changed files against the brief's scope.
3. Files outside scope: flag with the diff filename and the brief's stated scope. If a changed file is clearly unrelated (different module, no dependency), escalate flag severity.

---

## Check 5 — Base-Branch Staleness

**Goal:** prevent merging a branch that diverged from a base that has since advanced.

**Procedure:**

```bash
BASE_SHA=$(git -C "$WORKTREE" merge-base HEAD origin/$BASE_BRANCH)
CURRENT_BASE=$(git -C <repo-root> rev-parse origin/$BASE_BRANCH)
```

If `BASE_SHA != CURRENT_BASE`, the base has advanced since the branch was created.

Count commits on base since divergence:
```bash
git -C <repo-root> log --oneline "$BASE_SHA".."$CURRENT_BASE" | wc -l
```

**Verdict:**
- Base advanced → **block** (hard, day 1). Emit `base_stale` event. Achilles must rebase, then call Argus again.
- Base at same point → approve.

| Check | Block? |
|---|---|
| Base-branch staleness | yes (hard block, day 1) |

---

## Check 6 — Secrets / Credentials in Diff

Belt-and-braces check. GitHub secret scanning catches this at push, but Argus catches it before merge.

**Patterns to scan (in the diff's `+` lines only):**

```
- API keys: [Aa][Pp][Ii][_-]?[Kk][Ee][Yy]\s*=\s*["\'][A-Za-z0-9]{16,}
- Tokens: [Tt][Oo][Kk][Ee][Nn]\s*=\s*["\'][A-Za-z0-9+/]{20,}
- Passwords: [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\s*=\s*["\'][^"\']{8,}
- AWS keys: AKIA[0-9A-Z]{16}
- Private keys: -----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY
- JWT: eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}
- Hex secrets: [0-9a-fA-F]{32,64} (high entropy only — skip if in test fixtures or known-safe files)
```

Apply to the diff's added lines (`git diff --unified=0 | grep '^+'`). Skip lines starting with `+++ ` (file headers).

**Verdict:** Any match → **block** (hard, day 1). Include the matching line (redacted — show only first 8 chars + `...`) and file path.

| Check | Block? |
|---|---|
| Secrets/credentials in diff | yes (hard block, day 1) |

---

## TDD Verification (task type `test-tdd` only)

When the task brief has `Type: test-tdd`:

1. Check out the brief's starting commit (the commit before implementation began).
2. Run targeted tests at that commit: **expect failure** (tests should be red — they define unimplemented behavior).
3. Check out HEAD.
4. Run tests at HEAD: **expect pass** (implementation should satisfy the failing tests).

**Verdict:**
- Tests fail at start AND pass at HEAD → approve (red→green verified).
- Tests pass at start → flag "Tests were not actually red — TDD cycle may not have been followed."
- Tests fail at HEAD → block (implementation incomplete).

| Check | Block? |
|---|---|
| TDD tests fail at HEAD | yes (hard, day 1) |
| TDD tests were green at start commit | week1: flag |

---

## Review File Format

Argus writes findings to `<project-memory>/reviews/review_<task-id>.md`:

```markdown
# Argus Review: <task-id>
Reviewed: <ISO8601 timestamp>
Task size: <XS|S|M|L>
Verdict: approved | flagged | blocked
Block reason: <if blocked>

## Checks Run
- [pass] Check 5 — Base-branch staleness
- [pass] Check 6 — Secrets in diff
- [flag] Check 2 — Edge-case generation (3 uncovered cases)
- [skip] Test adequacy (XS/S — no test run)

## Findings
### [flag] Edge cases not covered by tests
| Edge case | Covered? |
|---|---|
| Empty input to FilterApplier.apply() | no |
| Cancellation mid-async in ExportManager | no |

### [flag] Diff anomaly: debug print
- `FilterApplier.swift:42` — `print("DEBUG filter result: \(result)")`

## Recommendations
- File follow-up task for uncovered edge cases (Chanakya will auto-file on `review_flagged` event)
- Remove debug print before any future M/L run
```

On `review_approved`: no file written (silent).
On `review_flagged`: write file, emit event with `review_file` path.
On `review_blocked`: write file, emit event, do NOT proceed to merge.
