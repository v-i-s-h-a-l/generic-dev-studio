---
name: Multi-Machine Sync Pattern
description: Tier-3 contract for multi-machine reconciled state. Partitioned by writer, append-only, merge at read time. No locks, no CRDTs, no coordination. Sync mechanism pluggable — GitHub private repo chosen for 2.5.
type: reference
---

# Multi-Machine Sync Pattern

Tier-3 of the three-tier artifact scheme (per `PHASE-2-5-PLAN.md` §0). Tier 1 = design artifacts in the repo tree. Tier 2 = per-machine runtime under `~/.dev-studio/<project>/`. Tier 3 = multi-machine reconciled state under `~/.dev-studio/<project>/shared/<machine-id>/`, append-only, partitioned by writer.

Shipping the contract and primitives in 2.5 prevents later phases from landing a fragile shared-mutable-state shortcut. First mode-pack consumer is deferred (see `PHASE-2-5-PLAN.md` §8).

## Rules — non-negotiable

1. **Partitioned by writer.** Every writer owns `~/.dev-studio/<project>/shared/<machine-id>/`. A writer never touches another writer's partition. Ever.
2. **Append-only within a partition.** No in-place updates. Files that look mutable from outside (e.g. per-day rollups) use atomic rename-new-file semantics: write `tmp/<file>.<uuid>` then `mv` into place. The reader sees a strictly-increasing collection.
3. **Merge at read-time.** A reader enumerates all partitions, unions their content, orders by `(occurred_at, machine-id)` for a stable total order. Partitions are never physically merged.
4. **Conflict-free by construction.** No two writers overlap. No locks, CRDTs, or coordination primitives are needed.
5. **Pluggable sync mechanism.** Any mechanism that preserves partition integrity works — git push/pull, rsync, S3, SMB. The sync primitive abstracts it.
6. **Lazy directory creation.** `shared/<machine-id>/` is created on first write, not eagerly provisioned.

## Tier map

| Tier | Path | Semantics | Writer |
|---|---|---|---|
| 1 | Repo tree | Design artifacts (docs, schemas). Git. | Collaborators via commits. |
| 2 | `~/.dev-studio/<project>/` | Per-machine runtime (briefs, worktrees, queues). | One machine. |
| 3 | `~/.dev-studio/<project>/shared/<machine-id>/` | Multi-machine reconciled state. | One partition per machine. |

## Primitives shipped in 2.5

- **`scripts/machine-id.sh`** — stable UUID per machine, written once to `~/.dev-studio/.runtime/machine-id`. Subsequent invocations read the cached value. Format: UUIDv4 string; opaque.
- **`scripts/write-shared.sh <logical-path> <content>`** — routes a logical path (e.g. `feedback/F-0042.json`) into the self-partition at `<shared>/<machine-id>/feedback/F-0042.json`. Append-or-atomic-rename per rule 2.
- **`scripts/read-shared.sh <logical-path>`** — enumerates all partitions that have the path, merges per contract, streams to stdout.
- **`scripts/sync-shared-remote.sh`** — implements the chosen GitHub-private-repo sync: push own partition, pull others, never touch others' partitions.

## Sync mechanism — GitHub private repo (chosen 2026-04-20)

Each machine pushes its own `shared/<machine-id>/` partition; pulls other machines' partitions. Append-only maps cleanly to git commits on a shared `main` branch — no conflicts because partitions never overlap. Works asymmetrically (either machine can be offline; the other catches up later). Free (private repos unlimited).

**Rationale for this choice.** The Mac mini offload scenario (memory `project_mac_mini_worker.md`) is the first real user; tests-only staging first, escalating to builds + uploads as credentials get provisioned.

**Future optimization — SSH + rsync over LAN/Tailscale.** Low-latency same-LAN mechanism may land later without breaking the contract (both machines online, skip git roundtrip). Not required for 2.5.

## Example — writing a feedback record

Machine A (`machine-id` = `abc123`):

```bash
./scripts/write-shared.sh feedback/F-0042.json "$(cat payload.json)"
# lands at ~/.dev-studio/<project>/shared/abc123/feedback/F-0042.json
./scripts/sync-shared-remote.sh
# pushes ~/.dev-studio/<project>/shared/abc123/ to GitHub
```

Machine B (`machine-id` = `def456`):

```bash
./scripts/sync-shared-remote.sh
# pulls ~/.dev-studio/<project>/shared/abc123/ from GitHub
./scripts/read-shared.sh feedback
# enumerates abc123/feedback/ + def456/feedback/, merges, streams
```

If machine B then writes its own record, it goes to `def456/feedback/F-0043.json` — never collides with `abc123/`.

## Read-time merge ordering

```python
# Pseudocode.
entries = []
for partition in list_partitions():
    for entry in read_path_in_partition(partition, logical_path):
        entries.append((entry.occurred_at, partition, entry))
entries.sort(key=lambda e: (e[0], e[1]))
for _, _, entry in entries:
    yield entry
```

Tiebreaker on identical `occurred_at`: `machine-id` lex-sort. Deterministic across machines.

## Testing strategy (Commit H)

Unit tests exercise:
- Single partition write + read.
- Two partitions with disjoint keys (merge produces union).
- Two partitions with same-timestamp entries (tiebreaker by machine-id).
- Atomic rename semantics (writer mid-rename; reader sees old file).
- Partition integrity (writer never writes outside own partition — a test that attempts to do so fails).

Fixture-based; no actual second machine required for 2.5 verification.

## Deferred

- First mode-pack consumer — no mode writes through `write-shared.sh` in 2.5.
- LAN / rsync sync mechanism — add only when latency becomes a real pain point.
- Conflict-resolution primitives — the contract is conflict-free; "resolution" is not a thing.

## Related

- `primitives/file-locations.md` — the three-tier root paths.
- `scripts/machine-id.sh` / `write-shared.sh` / `read-shared.sh` / `sync-shared-remote.sh` — primitives.
- `PHASE-2-5-PLAN.md` §3.13 / §8 — design and deferrals.
