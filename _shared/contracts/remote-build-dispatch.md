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
| `remote_timeout` | The worker command stream exceeded `NODE_BUILD_TIMEOUT` (default 1800s) and returned timeout exit code 124. | Check whether the build is genuinely hung; if needed, inspect or harvest the dispatch UUID log on the worker. |
| `build_invocation_failed` | The build/test command ran and returned non-zero. | Read the build log; fix code, project settings, signing, or tests. |
| `remote_marker_writer_failed` | The detached worker command ended, but the harness did not publish its `.exit` marker. Gate events include `remote_command_exit_code` when the worker log recorded it, plus bounded `remote_log_tail` context. | Inspect the tail first; then inspect the full dispatch UUID log under `~/.dev-studio/.runtime/logs/` on the worker if the tail is insufficient. |
| `remote_harness_failure` | The local gate could not read the worker log needed to classify the failure more specifically. | Inspect dispatch registry and worker logs; treat as infrastructure until proven otherwise. |

Debriefs and status summaries must surface the class above, not a generic “remote build failed” or “push your branch” hint.
