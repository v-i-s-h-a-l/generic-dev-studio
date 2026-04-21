---
name: Budget Telemetry Pattern
description: Every agent_session_completed event carries tokens + cost_usd. A mode_budget_exceeded event fires when a session total exceeds 1.1x budget. scripts/budget-report.sh aggregates daily/weekly; wired into compact mode.
type: reference
---

# Budget Telemetry

Token budgets without telemetry drift invisibly. This contract makes budget behavior observable with cheap additions to the existing `agent_session_completed` event — no new infra, no daemon, no dashboard.

## Rules

1. **`agent_session_completed` carries `tokens` + `cost_usd`.** The event already exists (see `events.md` Cross-agent events). `tokens` is the `{input, output, cache_read, cache_write}` object the agent has access to at end-of-session. `cost_usd` is derived:
   ```
   cost_usd = Σ(tokens.<kind> × model_rates[<model>].<kind>) / 1_000_000
   ```
   Per-model rates live in `_shared/schemas/model-rates.json`. If rates are missing for the model, omit `cost_usd` (do not emit 0 — misleading).
2. **`mode_budget_exceeded` event** fires when a session's total input+output tokens exceed `1.1 × budget_tokens` (where `budget_tokens` comes from the mode pack frontmatter). Emitted at session-completion, alongside `agent_session_completed`.
   ```json
   {
     "ts": "…",
     "agent": "achilles",
     "event": "mode_budget_exceeded",
     "task": "T001",
     "data": {
       "mode": "task",
       "budget_tokens": 6000,
       "actual_tokens": 7240,
       "ratio": 1.207
     }
   }
   ```
3. **`scripts/budget-report.sh`** reads the last N days of event logs, groups by `(agent, mode)`, prints tokens / cost / p50/p95 / budget-ratio per group. Wired into Chanakya compact mode so the user sees the report on every compact sweep.
4. **Budget is an envelope, not a hard cap.** Exceeding a budget emits an event; it does not abort a session. The event is a signal for future tuning (trim prose, raise budget, split mode).
5. **Missing `budget_tokens`** → fall back to `default_mode_budget` from `schemas/token-budgets.json`. Emit `W_BUDGET_DRIFT` at lint-time (per existing contract) when a mode grows past 1.1x its default.

## What `budget-report.sh` prints

```
Budget report (last 7 days)
Agent     Mode           Runs   p50 tok   p95 tok   Budget   p95/budget   $spent
achilles  task            14    5200      7100      6000     1.18         $2.14
chanakya  brief           22    2300      3500      3000     1.17         $0.89
argus     review          14    4100      5800      5000     1.16         $1.68
...
Total runs: 50   Total spend: $4.71
```

## What this replaces

- Speculative budgets with no feedback loop. Prior to telemetry, seed values stayed stale.
- Ad-hoc "did this session feel expensive" guesswork.

## Non-goals

- Live streaming dashboard. The 6+ project-wide dashboard (Phase 6) reads from this data; but 2.5 just emits + aggregates.
- Pre-flight budget rejection. Never block a session on budget — signal only.

## Related

- `schemas/token-budgets.json` — per-mode budget seed values.
- `schemas/model-rates.json` — per-model USD rates for `cost_usd` derivation.
- `events.md` — `agent_session_completed` + `mode_budget_exceeded` catalog entries.
- `scripts/budget-report.sh` — aggregator; ships in Commit F.
