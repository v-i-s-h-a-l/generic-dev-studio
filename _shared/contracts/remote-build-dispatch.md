---
name: Remote Build Dispatch
description: Contract for rsync-backed worker-node build/test dispatch and diagnostics.
type: reference
---

# Remote Build Dispatch

Build gates dispatch to worker nodes by mirroring the local worktree with `scripts/lib-source-sync.sh`, then invoking `scripts/node-dispatch.sh` over SSH. The remote does not consume an already-pushed Git branch for normal task builds. A suggestion to push the branch is therefore not valid recovery for rsync-backed dispatch failures.

## Failure Classes

| Class | Meaning | Operator action |
|---|---|---|
| `source_sync_failed` | rsync to the worker failed before the build command ran. | Check node reachability, SSH, disk, and rsync. |
| `remote_shell_path_failed` | The worker shell started, but `cd`, `swift`, `xcodebuild`, or PATH setup failed. | Run `scripts/node-diagnose.sh <node>` and sync/bootstrap the worker. |
| `build_invocation_failed` | The build/test command ran and returned non-zero. | Read the build log; fix code, project settings, signing, or tests. |
| `remote_success_marker_missing` | The detached worker harness did not publish its `.exit` marker. | Inspect the dispatch UUID log under `~/.dev-studio/.runtime/logs/` on the worker. |
| `remote_harness_failure` | The local gate could not read the worker log needed to classify the failure more specifically. | Inspect dispatch registry and worker logs; treat as infrastructure until proven otherwise. |

Debriefs and status summaries must surface the class above, not a generic “remote build failed” or “push your branch” hint.
