---
name: Model Catalog and Reviewer Policy
description: How _shared/schemas/model-catalog.yaml and _shared/rules/model-policy.yaml drive PR-review host/model/effort selection. Refresh cadence, reviewer-independence enforcement, and impl-host signal priority for issue #322.
type: reference
---

# Model catalog and reviewer model policy

Two sibling files own model selection for the Forge PR review path:

- `_shared/schemas/model-catalog.yaml` — which models exist, per provider family.
- `_shared/rules/model-policy.yaml` — how roles map to tiers and how reviewer independence is enforced.

Together they replace ad-hoc model strings buried in shell scripts and mode prose. Model names move on a 3-4 week cadence (issue #322); script changes do not. Keeping the names in YAML makes refresh a single edit instead of a scavenger hunt.

## Resolution flow

`scripts/resolve-reviewer.sh` (pure bash + `yq`, **zero LLM tokens** spent on selection) consumes both files plus `hosts/registry.yaml` and emits a host + model + reasoning-effort triple to the caller. The caller (`scripts/pr-headless-review.sh`) then appends the model args to the reviewer's `spawn_command` from the host's `capabilities.yaml`.

```
+-----------------------------+      +--------------------------+
| hosts/registry.yaml         |      | _shared/schemas/         |
| (provider_family per host)  | ---> | model-catalog.yaml       |
+-----------------------------+      +--------------------------+
                  |                              |
                  v                              v
           +------------------------------------------+
           | scripts/resolve-reviewer.sh              |
           | (impl host -> family,                    |
           |  picks reviewer host + model + effort)   |
           +------------------------------------------+
                              |
                              v
           +------------------------------------------+
           | scripts/pr-headless-review.sh            |
           | (spawns reviewer with appended args)     |
           +------------------------------------------+
```

## Refresh cadence

Per the cadence decision recorded on issue #322:

- **Default refresh interval:** every 3-4 weeks. Update `last_refreshed_at` and `next_refresh_due` at the top of `model-catalog.yaml` on each pass.
- **Manual refresh triggers:** the user explicitly asks, or a provider/model failure indicates drift.
- **Never live-fetched at gate time.** PR review and merge paths read the checked-in catalog only.

A refresh pass walks each entry against the provider's `source_url`, updates `id`, `aliases`, `dated_snapshot`, and stamps `last_verified_at`. Entries with `last_verified_at: null` are placeholders — treat them as needs-refresh.

## Reviewer independence

The policy file enforces that reviewer host family differs from implementation host family by default. When only same-family reviewers are available, the resolver escalates the intelligence tier one notch (`medium`→`high`, `high`→`max`, `max`→`max`) rather than blocking — this matches the user direction on #322 (2026-04-30): "use the higher intelligence level (medium → reviewed by high, max by max), and the topmost family opus/GPT-5 etc."

Hard block (requiring `--user-approved-bypass` on `pr-autopilot.sh`) only fires when **no** reviewer host is eligible at all (none installed, all failing eligibility, etc.).

## Implementation host signal

`pr-headless-review.sh` learns the implementer in this priority order:

1. `--impl-host <h>` flag.
2. `STUDIO_IMPL_HOST` env var.
3. `Studio-Impl-Host:` trailer on the most recent non-merge commit of the PR (forward-compatible — Achilles emits this in a future change).
4. `unknown` — no exclusion is applied; the resolver picks any eligible reviewer.

Manual Achilles dispatch (today's mode) typically uses the flag or env var. Automated dispatch will lean on the trailer once Achilles emits it.
