# turnip-ios-phase-2-6-5 fixture

A trimmed snapshot of a real turnip-ios ledger state, used for Phase 2.6.5 replay validation. Not checked in with real project data — fixture is seeded in the commit that first uses it (Phase 2.6.5 commit 5+). The `plans/` subtree and `events/` dir are scaffolded empty with `.gitkeep` placeholders; replay tests populate them via `scripts/replay-fixture.sh` (forthcoming).

Consumers: `scripts/verify-ledger.sh`, `scripts/replay-fixture.sh`, and any extraction script that needs a deterministic before/after pair.
