# Shared: Build Debt Schema

The master plan's `## Build Debt` block is the source of truth. Chanakya owns all writes; Achilles only reads.

```markdown
## Build Debt
- Counter: 8 / warn@6 / block@12
- State: warn            <!-- silent | warn | block -->
- Last green: build-20260414-093200 (2026-04-14 09:32)
- Last green SHA: a1b2c3d
- Unverified since: [T015, T016, T017, T018, T019, T020, T021, T022]
- Open check task: TBUILD-3
- Blocked by: —          <!-- only set when a red build check outstanding; points to P0 fix task -->
- Next TBUILD n: 4
```

## Counter Update Rules (applied by Chanakya per debrief)

| Debrief `build_gate` | Debrief `build_debt_override` | Action |
|---|---|---|
| `full-green` | false | Counter → 0; `State: silent`; update `Last green`; clear `Unverified since`; close open TBUILD. |
| `lsp-only` | false | Counter += 1; append task-id to `Unverified since`. |
| `lsp-only` | true | Counter += 1; append `<task-id>[overridden]` to `Unverified since`. |
| `full-green` | true | Counter → 0; override flag irrelevant (real full-green clears debt regardless). |

## State Transitions

- `Counter = 0` → `State: silent`
- `Counter ∈ [1, 5]` → `State: silent`
- `Counter ∈ [6, 11]` → `State: warn`. File TBUILD on the 5→6 transition.
- `Counter ≥ 12` → `State: block`
- `Blocked by: T<nnn>` outstanding → `State: block` regardless of counter.

## Achilles: Build Debt Gate (Step 1.5)

Read the `## Build Debt` block before starting any task:

- **Counter ≤ 5:** proceed silently.
- **Counter 6–11 (warn):** print one-line banner, proceed.
  > "⚠️ Build debt: 8 tasks merged without a full build. Run `/achilles build` when convenient. (Block at 12 — 4 more until new work refused.)"
- **Counter ≥ 12 (block):**
  - If task has `Source: build-debt` in master plan (it's a TBUILD): proceed — exempt.
  - If `--ignore-build-debt` passed: print override banner and proceed. Record `build_debt_override: true` in debrief.
  - Otherwise: print block banner and exit without claiming.
    > "⛔ Build debt blocked at 12. Run `/achilles build` before starting new work. Override (not recommended): `/achilles <task-id> --ignore-build-debt`."

Never write to the master plan during this gate.
