# Pi adapter research — 06 Skill/package distribution

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Skill/package distribution under a Pi adapter |
| Task graph node | `T-R006` |
| Source issue | [#929](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/929) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b8d-09dc-7a7a-a920-d15b3b173ae8` |
| Chain | `pi-adapter-research-codex-continuation` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/06-skill-package-distribution.md` |
| Classification | private-runtime (not committed) |

The private artifact compares Studio's canonical skill source, host-global
symlink fanout, vendored-skill loader, recipes, and router-skill portability
metadata with Pi's skills, settings, and package-resource model. It concludes
that Studio skills should remain canonical in this repo, while Pi-facing skill
and package views should be generated or symlinked after the adapter boundary is
decided. The recommended first adapter step is Pi host-target fanout or Pi
settings-path loading, not publishing a Pi package or replacing Studio's
`portability.yaml`, `routing.yaml`, recipes, vendored pins, or
`sync-host-skills.sh`. It is research only: no Pi install, no package publish,
no skill fanout removal, no credentials or Pi state touched, and no adapter
architecture decision.

Downstream research outputs (`07-current-workflow-feasibility.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
