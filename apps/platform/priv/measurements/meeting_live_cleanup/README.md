# Historical live task cleanup — task 01a17f00-832c-7000-b480-64ab6d710532

This is the explicitly authorized production one-off. It does not use
`junk_batch/2`, which also removes officer-filed tasks. No hard delete, candidate
edit, or task status filter is used. Audit failure rolls the batch back. An
officer canvas stamp or inconsistent candidate provenance refuses the batch.
Each batch is bounded to 250 rows (API maximum 500). Audits store exact task IDs,
actor, operation identity, selector, count and pruned briefing IDs. Only selected
task entries are pruned from existing meeting briefings; receipts and other
content remain. Existing consumers are notified without creating historical
briefings or new push notifications.

## Before deployment

After tests/lint pass, copy the validated `triage.ex`, `run_release.exs` and
`verify_release.exs` to the authorized runtime. The installation-specific host,
container, actor, operation identity and exact transport command belong in the
execution space/journal, not this public repository. Set CLEANUP_CONTAINER on
that runtime and replace ACTOR_UUID and OPERATION_ID below with the authorized
run's values.

The tested adapter compiles a distinct one-off module from selected validated
functions; it does not replace the running application module.

```sh
podman cp /tmp/meeting-live-cleanup-triage.ex "$CLEANUP_CONTAINER":/tmp/meeting-live-cleanup-triage.ex
podman cp /tmp/meeting-live-cleanup-run.exs "$CLEANUP_CONTAINER":/tmp/meeting-live-cleanup-run.exs
podman cp /tmp/meeting-live-cleanup-verify.exs "$CLEANUP_CONTAINER":/tmp/meeting-live-cleanup-verify.exs
podman exec "$CLEANUP_CONTAINER" bin/platform rpc 'Code.eval_file("/tmp/meeting-live-cleanup-verify.exs")'
# Dry-run is the default. No task content is printed.
podman exec "$CLEANUP_CONTAINER" bin/platform rpc 'Code.eval_file("/tmp/meeting-live-cleanup-run.exs")'
# Repeat bounded apply until remaining=0, then repeat once to prove
# changed=0/audit_id=null with no duplicate audit.
podman exec "$CLEANUP_CONTAINER" bin/platform rpc 'Code.eval_string(File.read!("/tmp/meeting-live-cleanup-run.exs"), cleanup_apply: true, cleanup_actor_id: "ACTOR_UUID", cleanup_operation_id: "OPERATION_ID")'
podman exec "$CLEANUP_CONTAINER" bin/platform rpc 'Code.eval_file("/tmp/meeting-live-cleanup-verify.exs")'
```

`verify_release.exs` prints counts and a digest of officer task IDs/deletion
state. The initial production snapshot had zero officer source/canvas-stamped
tasks. Preservation is tested with populated same-meeting fixtures; that zero
cannot prove preservation of populated production officer rows.

## Required deployer action after cutover

A pre-cutover zero does not mean cleanup is permanently complete: old live code
can still mint until deployment. Verify the deployed revision, then invoke the
now-deployed API with the same operation identity. Repeat until `remaining=0`:

```sh
podman exec "$CLEANUP_CONTAINER" bin/platform rpc 'case Platform.Meetings.Triage.junk_live_tasks(dry_run: false, limit: 250, actor_id: "ACTOR_UUID", operation_id: "OPERATION_ID") do {:ok, report} -> IO.puts(Jason.encode!(report)); {:error, reason} -> raise inspect(reason) end'
```

Run the verifier again and require `live_selector_survivors=0`. Record the
post-cutover timestamp, additional changed count and audit IDs. A provenance
conflict or nonzero survivor count needs resolution; it is not a completed
cleanup. Compare the protected inventory digest/count with the pre-run snapshot.

## Falsifier

If selected IDs include an officer/canvas-stamped task, or live-selector
survivors remain after an exhausted cutover run, stop and rederive the selector.
Do not broaden the selector around a conflict.
