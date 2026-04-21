---
name: Singleton Invariants
description: Which agents must run as a single instance per machine and why. Breaking these invariants has caused real bugs; document keeps the constraint load-bearing.
type: reference
---

# Singleton Invariants

Some agents in the studio must run as exactly one instance at a time. This file records which ones, why, and how to detect violations. Cross-referenced from `_shared/patterns/router-pattern.md` and any refactor touching these agents.

## Singletons

### Chanakya — singleton per machine

**Invariant.** Only one `/chanakya` session may be active on this machine at a time.

**Why.**
1. **Task-id assignment conflicts.** Chanakya issues monotonic task IDs when briefing. Two concurrent instances each pick the same "next" ID, producing colliding briefs. Observed in practice.
2. **Away-mode communication assumes a single listener.** The event log + push-queue shape is designed around one consumer of pending events. Two instances race to consume each event, corrupting state.
3. **Snapshot generation.** Multiple writers to the same snapshot file produce interleaved or partial content. No file locking today.

**How to enforce (today).** Advisory. Any refactor or new flow that could spawn a second Chanakya **must** explicitly call out the violation and propose an alternative (e.g. a worker that emits events instead of being a full Chanakya).

**How to enforce (planned).** A PID+start-time lockfile at `~/.dev-studio/<project>/.runtime/state/chanakya.lock`. Second launch detects, warns, and either aborts or opens read-only. Tracked separately; do not block router refactor on this.

**Cross-project.** One Chanakya per project is fine — the singleton is *per project*, not machine-wide, because runtime state lives under `~/.dev-studio/<project>/`. Two projects on the same machine can each run their own Chanakya safely.

## Not singleton (safe to run many)

### Achilles — worktree-isolated

Achilles works on an isolated git worktree per task. Multiple Achilles instances on the same machine are already routine (brief fleet mode). No shared writable state except the event log (append-only, safe) and the push-queue (consumed only by Chanakya).

### Argus — stateless

Argus reads a diff and writes a verdict file scoped to the task ID. Multiple Argus instances on different tasks are safe. Two Argus runs on the *same* task overwrite each other's verdict file — caller responsibility to not double-invoke.

### Lu Ban — design-slug isolated

Lu Ban writes to `plans/designs/<slug>/`. Two concurrent Lu Ban sessions on *different* slugs are safe. Two sessions on the *same* slug race — convention: one design session per slug until `status: approved`, enforced by Lu Ban checking the slug directory at session start.

## Change procedure

Any refactor that could affect singleton semantics is ask-tier per REVIEW.md. Specifically:
- Introducing cross-process coordination (shared locks, daemons, queues).
- Changing how task IDs are minted.
- Changing how away-mode communicates with live Chanakya.
- Allowing parallel snapshot writers.

If you're tempted to break a singleton to parallelize work, first check whether the work can be split into stateless workers that *emit events* for Chanakya to consume, rather than becoming a second Chanakya.

## History

- Multi-instance Chanakya was attempted; surfaced task-id collision in production. Not re-attempted. Keep the constraint.
