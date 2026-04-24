---
ts: 2026-04-23T14:16:58Z
kind: bug
scope: generic-dev-studio
---

## Abstract pattern

Tasks T277, T300, T302, T304 completed but debrief sweep missed them.
Files involved: `chanakya-master.md`, `chanakya-inbox/T304-debrief.md`,
`debriefs/T302-*.yaml`, and the enumerator `sweep-enumerate-debriefs.sh`.

TBUILD-3 and TUNIT-12 style IDs should also pass. Paths like
`scripts/ingest-feedback.sh` are not secrets.
