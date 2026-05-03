# Studio v2 A10 Recovery Playbook

This playbook is the operator-facing recovery path after A10 deletes the v1
surfaces. A10 does not keep an in-tree `legacy/v1` copy; recovery uses git
history.

<!-- v2-cutover:rollback-playbook -->
## Trigger

Recovery is appropriate when v2 traffic cannot satisfy one of the parity
scenarios in `core/v2/cutover/manifest.yaml`, when a migrated role contract
cannot resolve, or when the operator reports a v2 traffic regression after A10.

## Steps

1. Identify the pre-A10 commit from the A10 PR or `git log`.
2. Restore the deleted v1 surfaces with:

```bash
git checkout <pre-a10-commit> -- .claude/skills/studio chanakya achilles argus apollo
```

3. Restore `core/v2/skills/dev-studio/forwarders.yaml` `forwarders[]` rows and
   `transition.cutover_status: cut-over` from the pre-A10 commit if the v1
   forwarders must run again.
4. Restore `core/v2/cutover/manifest.yaml` `status: cut-over`,
   `traffic_switch.cutover_status: cut-over`, and compatibility forwarder rows
   if restored forwarders will be kept live.
5. Run:

```bash
scripts/v2-cutover.sh --validate
scripts/test-fixtures/527-cutover/test-v2-cutover.sh
```

6. Record the recovery event and reopen A10 before retrying deletion.
