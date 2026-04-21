---
name: Budget Telemetry Pattern
description: Every agent_session_completed event carries tokens + derived cache_hit_rate + ctx_util_pct. A mode_budget_exceeded event fires when a session total exceeds 1.1x budget. scripts/budget-report.sh aggregates daily/weekly; wired into compact mode.
type: reference
---

# Budget Telemetry

Token budgets without telemetry drift invisibly. This contract makes budget behavior observable with cheap additions to the existing `agent_session_completed` event — no new infra, no daemon, no dashboard.

The user is on the Claude Max plan (flat subscription, not per-token billing). Budget framing is consumption, not spend. Reject features on quality / rate-limit / resource grounds, not billing — see memory `feedback_max_plan_pricing.md`.

## Rules

1. **`agent_session_completed` carries `tokens`.** The event already exists (see `events.md` Cross-agent events). `tokens` is the `{input, output, cache_read, cache_write}` object the agent has access to at end-of-session. Two derived metrics are aggregated at report time (not stored on the event):
   - `cache_hit_rate = cache_read / (cache_read + input)` — higher is better; a warm cache amortizes the full-context load.
   - `ctx_util_pct = (input + cache_read) / context_window_tokens` — peak context pressure for the mode.
   The raw tokens are the source of truth; cost derivation is explicitly out of scope under the Max plan.
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
3. **`scripts/budget-report.sh`** reads the last N days of event logs, groups by `(agent, mode)`, prints tokens / cache_hit_rate / ctx_util_pct / budget-ratio per group. Wired into Chanakya compact mode so the user sees the report on every compact sweep.
4. **Budget is an envelope, not a hard cap.** Exceeding a budget emits an event; it does not abort a session. The event is a signal for future tuning (trim prose, raise budget, split mode).
5. **Missing `budget_tokens`** → fall back to `default_mode_budget` from `schemas/token-budgets.json`. Emit `W_BUDGET_DRIFT` at lint-time (per existing contract) when a mode grows past 1.1x its default.

## What `budget-report.sh` prints

```
Budget report (last 7 days)
Agent     Mode           Runs   p50 tok   p95 tok   Budget   p95/budget   cache_hit   ctx_util
achilles  task            14    5200      7100      6000     1.18         0.64        0.42
chanakya  brief           22    2300      3500      3000     1.17         0.71        0.19
argus     review          14    4100      5800      5000     1.16         0.58        0.31
...
Total runs: 50
```

## What this replaces

- Speculative budgets with no feedback loop. Prior to telemetry, seed values stayed stale.
- Ad-hoc "did this session feel expensive" guesswork.
- Prior $-denominated cost column (dropped 2026-04-22 under the Max-plan reframe — see memory `feedback_max_plan_pricing.md`).

## Non-goals

- Live streaming dashboard. The Phase 6 dashboard reads from this data; but the 2.x cycle just emits + aggregates.
- Pre-flight budget rejection. Never block a session on budget — signal only.
- Per-token $ telemetry. Out of scope under Max plan.

## Related

- `schemas/token-budgets.json` — per-mode budget seed values.
- `schemas/model-rates.json` — **deprecated 2026-04-22** (was per-model USD rates; unused post-reframe). Kept one cycle for any out-of-tree reader; remove at Phase 2.7 cutover.
- `events.md` — `agent_session_completed` + `mode_budget_exceeded` catalog entries.
- `scripts/budget-report.sh` — aggregator; wired into Chanakya compact mode.
