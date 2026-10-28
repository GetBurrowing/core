# Historical live task cleanup — task 01a17f00-832c-7000-b480-64ab6d710532

This is the explicitly authorized Kobo one-off. It does not use `junk_batch/2`,
which also removes officer-filed tasks. No hard delete, candidate edit, or task
status filter is used. Audit failure rolls the batch back. An officer canvas
stamp or inconsistent candidate provenance refuses the batch rather than
silently widening the scope. Each batch is bounded to 250 rows (API maximum500).
The audit stores exact task IDs, actor, operation identity, selector, count and
pruned briefing IDs. Only corresponding task entries are pruned from meeting
briefing items; receipts and other content remain.

## Before deployment

Run these commands from this task's validated worktree, after test/lint evidence.
They use the tested release adapter because production does not yet contain the
new API. The adapter compiles a distinct one-off module from selected validated
functions; it does not replace the running `Triage` module.

```sh
scp apps/platform/lib/platform/meetings/triage.ex rocks@192.168.1.200:/tmp/meeting-live-cleanup-triage.ex
scp apps/platform/priv/measurements/meeting_live_cleanup/run_release.exs rocks@192.168.1.200:/tmp/meeting-live-cleanup-run.exs
scp apps/platform/priv/measurements/meeting_live_cleanup/verify_release.exs rocks@192.168.1.200:/tmp/meeting-live-cleanup-verify.exs
ssh rocks@192.168.1.200 'podman cp /tmp/meeting-live-cleanup-triage.ex core-platform:/tmp/meeting-live-cleanup-triage.ex'
ssh rocks@192.168.1.200 'podman cp /tmp/meeting-live-cleanup-run.exs core-platform:/tmp/meeting-live-cleanup-run.exs'
ssh rocks@192.168.1.200 'podman cp /tmp/meeting-live-cleanup-verify.exs core-platform:/tmp/meeting-live-cleanup-verify.exs'
ssh rocks@192.168.1.200 'podman exec core-platform bin/platform rpc '\''Code.eval_file("/tmp/meeting-live-cleanup-verify.exs")'\'''
# Dry-run (default); no task content is printed.
ssh rocks@192.168.1.200 'podman exec core-platform bin/platform rpc '\''Code.eval_file("/tmp/meeting-live-cleanup-run.exs")'\'''
# Authorized audited apply; repeat until remaining=0, then repeat once to
# demonstrate changed=0/audit_id=null. No second audit for an empty batch.
ssh rocks@192.168.1.200 'podman exec -e MEETING_CLEANUP_APPLY=true core-platform bin/platform rpc '\''Code.eval_file("/tmp/meeting-live-cleanup-run.exs")'\'''
ssh rocks@192.168.1.200 'podman exec core-platform bin/platform rpc '\''Code.eval_file("/tmp/meeting-live-cleanup-verify.exs")'\'''
```

`verify_release.exs` produces only counts and a digest of officer task IDs plus
their deletion state. The initial production measurement had **zero** officer
source/canvas-stamped tasks: preservation is tested with same-meeting fixtures;
the production zero does not independently prove preservation of populated
historical officer rows.

## Required deployer action after cutover

**A pre-cutover zero does not mean cleanup is permanently complete.** Live code
can still mint until this branch is deployed. After verifying the deployed
revision, invoke the now-deployed API with the same operation identity, repeating
bounded batches until `remaining=0`:

```sh
ssh rocks@192.168.1.200 'podman exec core-platform bin/platform rpc '\''case Platform.Meetings.Triage.junk_live_tasks(dry_run: false, limit: 250, actor_id: "01a13fd8-a480-7000-93a3-7a5c68a769af", operation_id: "01a17f00-live-task-cleanup-20261028") do {:ok, report} -> IO.puts(Jason.encode!(report)); {:error, reason} -> raise inspect(reason) end'\'''
```

Then copy/run `verify_release.exs` again and require
`live_selector_survivors=0`. Report the post-cutover measurement timestamp,
additional changed count and audit IDs. A provenance conflict or nonzero survivor
count is a failure to resolve, never evidence of completed cleanup. Compare the
protected inventory digest/count with the pre-run snapshot; investigate changes.

## Falsifier

A fixture or production measurement showing that the selected task IDs include
an officer/canvas-stamped task, or that live-selector survivors remain after an
exhausted cutover run, contradicts the cleanup claim. Stop and rederive the
selector; do not broaden it around a conflict.
