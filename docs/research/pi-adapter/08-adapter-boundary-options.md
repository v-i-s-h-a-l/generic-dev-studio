# Pi adapter research — 08 Adapter boundary design options

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Adapter boundary design options |
| Task graph node | `T-R008` |
| Source issue | [#931](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/931) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b8d-09dc-7a7a-a920-d15b3b173ae8` |
| Chain | `pi-adapter-research-codex-continuation` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/08-adapter-boundary-options.md` |
| Classification | private-runtime (not committed) |

The private artifact compares an in-tree Pi host adapter, a separate Pi
package/repo, and a hybrid generated-package model. It recommends starting with
an in-tree `pi` host adapter and a small Studio-owned JSON execution envelope,
then generating a Pi package later only as a reproducible distribution view
after conformance passes. It is research only: no Pi install, no package
publish, no credentials or Pi state touched, and no implementation.

Downstream research outputs (`09-issue-sweep.md` and `10-final-synthesis.md`)
follow the same private-artifact + repo-pointer pattern when they ship.
