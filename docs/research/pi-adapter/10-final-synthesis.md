# Pi adapter research — 10 Final synthesis and implementation-plan outline

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Final synthesis and implementation-plan outline |
| Task graph node | `T-R010` |
| Source issue | [#933](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/933) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b8d-09dc-7a7a-a920-d15b3b173ae8` |
| Chain | `pi-adapter-research-codex-continuation` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/10-final-synthesis.md` |
| Classification | private-runtime (not committed) |

The private artifact synthesizes the Pi adapter research into keep/core,
bridge, optional-under-pi, replaceable-after-parity, defer, and unknown
classifications. It recommends starting with an in-tree Pi host adapter and a
Studio-owned JSON execution envelope, proving dry-run/read-only workflows first,
then live worker conformance, then reviewer profile support, and only later a
generated Pi package. It is research only: no Pi install, no implementation,
no issue creation, no GitHub issue mutation, and no credential or Pi state
changes.
