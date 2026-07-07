# 2026-07-03 DataCase cascade — root cause

Task: `019f3440-4a38-766f-8ec0-43026aaf209a`
Symptom pinned: CI job 85296636791 on `b3339a24` (main) — mass
`DBConnection.OwnershipError cannot find ownership process for
#PID<...> (Task.Supervised)` cascade blocks every `data_case.ex:24`
setup after the first one triggers.

## Verified trace (HEAD `b3339a24`, verified in stage 1)

1. `Summarizer.summarize_async/1`
   (`apps/platform/lib/platform/meetings/summarizer.ex:58`) does
   `Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
   run_summary(transcript) end)`. The spawned process is **not**
   in DataCase's `supervised_with_repo` allow-list
   (`apps/platform/test/support/data_case.ex:33-37`, only
   `AttentionRouter` / `ContextBroker` / `ContextPlane`).
2. `run_summary/1` gates on
   `router_meetings_summarize_filled?/0` → calls
   `ResponsibilityRouter.responsibility_filled?/1` (`router.ex:290`) →
   `safe_assignee_for/1` (`router.ex:1226`) → `Roles.assignee_for/1`
   (`roles.ex:354`) → `Repo.one/2`. **First** OwnershipError raise.
3. The existing `rescue error ->` at `router.ex:1231` catches it,
   logs at `:warning` (`"[ResponsibilityRouter] Roles.assignee_for/1
   raised key=meetings.summarize: cannot find ownership process for
   #PID<...> (Task.Supervised)"`), returns `nil`.
   `responsibility_filled?/1` → `false`.
4. `run_summary/1` falls through to
   `run_summary_legacy/3` (`summarizer.ex:161`) → `call_llm/3`
   returns `{:error, :no_summary_provider_configured}` in test env
   (`config/test.exs` has no meetings.yml → `provider: :none`) →
   line 210 calls `Meetings.fail_transcript(id)` → `Repo.update/1` →
   **second** OwnershipError raise.
5. The outer `rescue e ->` at `summarizer.ex:213` catches THAT
   raise, logs `"[Summarizer] Unexpected error for transcript ...:
   cannot find ownership process for #PID<...>"`, then at
   `summarizer.ex:216` calls `Meetings.fail_transcript(id)` **again**.
   A `rescue` block does not wrap itself, so **this third raise
   escapes the Task**.
6. Uncaught OwnershipError propagates through
   `Task.Supervised.invoke_mfa/2` (`lib/task/supervised.ex:105`).
   The `Platform.TaskSupervisor` child terminates abnormally.
7. In the same test batch, `Platform.Orchestration.TaskRouterWatcher`
   receives a `{:task_updated, ...}` PubSub broadcast (from any
   concurrent test that inserts / updates a task row) and runs
   `resolve_runtime_for_task/1` → `Repo.get(Platform.Agents.Agent,
   agent_id)` at `task_router_watcher.ex:167` UNGUARDED. Watcher is
   a globally-supervised singleton NOT in DataCase's allow-list, so
   this `Repo.get` also raises OwnershipError → GenServer
   terminates → supervisor restarts it OUTSIDE the DataCase owner
   chain → every subsequent `data_case.ex:24` sandbox checkout
   fails.

## PR provenance

| PR | Commit | Contribution to cascade |
|---|---|---|
| #474 | `216a3f88` "Retire Historian on agent.system_events; cut over to Roles-based Historian" | Introduced `Platform.Roles.assignee_for/1` (`roles.ex:354`) and the `Repo.one/2` behind it. Before this PR the router path either short-circuited on missing module or read no DB. |
| #480 | `243252ae` "Prompt templates for closed-roster responsibilities (019f2455)" | Seeded `meetings.summarize` prompt templates and made the Meeting Scribe / Triage Officer / Historian / Designer bundles registrable. Widened the set of tests that boot `Responsibilities.Registry` with the summarize responsibility loaded → widened the surface where `safe_assignee_for/1` actually runs its `Repo.one/2` under `Task.Supervised`. Did NOT itself seed a `RoleAssignment`. |
| #481 | `83eaeeae` "Responsibility router heartbeat + fallback for stalled dispatches (019f2566)" | Shipped `Meetings.SummarizerSweeper` and `Responsibilities.StallRegistry`, both of which use `Task.Supervisor.async_nolink(Platform.TaskSupervisor, ...)` around `Summarizer.run_summary_legacy/3`. Gated OFF in test env (`config/test.exs:97,102`) so they don't directly drive the cascade, but they made the double-`fail_transcript`-inside-rescue code path load-bearing production behaviour and raised the priority of fixing it. |

On `3cf980af` (last known green pre-#474) the router's
`safe_assignee_for/1` short-circuits on `not Code.ensure_loaded?(
Platform.Roles)` → no `Repo` query runs from a `Task.Supervised`
process → the leak's step-1 DB touch simply doesn't happen and no
matter how many summarize tasks a test spawns, none raise.

## Stage 1 deliverables

* Regression test at
  `apps/platform/test/platform/regression/task_supervisor_ownership_leak_test.exs`
  — tagged `@moduletag :cascade_repro`. Excluded from default `mix
  test` via `test_helper.exs`; invoke explicitly via `mix test
  --only cascade_repro`. Reproduces the escape by (a) clearing the
  spawn's `$callers` chain via `Process.put(:"$callers", [])` on an
  intermediate `spawn/1` process — this mirrors production where
  `Summarizer.summarize_async/1` is invoked from a Cowboy handler or
  Router GenServer that isn't itself sandbox-owned, (b) calling
  `Summarizer.summarize_async/1` from that intermediate process,
  and (c) monitoring the Task-Supervised child and asserting it
  exits `:normal` and the transcript reaches a terminal state.
  Pre-fix, the child exits with `{%DBConnection.OwnershipError{}, [
  ...fail_transcript at meetings.ex:1447, run_summary_legacy at
  summarizer.ex:216, Task.Supervised.invoke_mfa]}` — proving the
  double-`fail_transcript`-in-rescue escape at summarizer.ex:216.
  Post-fix (stage 2), the child exits `:normal` and the transcript
  is `"failed"`.
* This notes file.

## Verified — regression test FAILS on `b3339a24`

The test at `test/platform/regression/task_supervisor_ownership_leak_test.exs`
fails deterministically with:

    Task-Supervised process exited abnormally (leak still present).
    Reason: {%DBConnection.OwnershipError{...}, [
      ...
      {Platform.Meetings, :fail_transcript, 1,
       [file: ~c"lib/platform/meetings.ex", line: 1447]},
      {Platform.Meetings.Summarizer, :run_summary_legacy, 3,
       [file: ~c"lib/platform/meetings/summarizer.ex", line: 216]},
      {Task.Supervised, :invoke_mfa, 2, ...}
    ]}

Line 216 is INSIDE the rescue block that catches the first
`fail_transcript` raise — the second call escapes because a `rescue`
block does not wrap itself. This locks step 6 of the trace as the
load-bearing escape point.

## Stage 2 priority (recommendation for the executor)

Planner asked for three defensive edits. Priority order derived from
the trace:

1. **PRIMARY — `summarizer.ex:213-218` rescue block.** The escape
   point is `Meetings.fail_transcript` re-called inside the rescue.
   Either wrap the rescue body in `try` or, more surgically, guard
   `Meetings.fail_transcript` calls with a
   `try/rescue DBConnection.OwnershipError -> :ok`. This is the
   direct fix for the escape.
2. **BELT — `task_router_watcher.ex:167` `resolve_runtime_for_task/1`.**
   Even with #1 in place, any future singleton that touches DB from
   a PubSub broadcast will hit the same shape. Guard `Repo.get` +
   `Federation.get_runtime_for_agent` with
   `try/rescue DBConnection.OwnershipError -> {:error,
   :sandbox_unowned}`.
3. **BRACES — `router.ex:825` `fire_trigger/3` outer body.** The
   downstream `dispatch_external → gather_context_via_provider →
   ContextGatherer.gather` chain is already `rescue`-safe today, but
   any future call site added there would silently re-open the leak.
   Wrap the outer body with a defensive `try/rescue/catch :exit`
   that returns `:ok`.
4. **BRACES — `data_case.ex:33-37` allow-list.** Append
   `Platform.Orchestration.TaskRouterWatcher` and
   `Platform.Responsibilities.Router` (the guard `if pid =
   Process.whereis(name)` in the `Enum.each` already handles both
   being absent). Makes the happy path work even when a test does
   drive the singletons into a DB touch.

Fix #1 alone is sufficient to make the stage-1 repro test PASS. #2
is required for the CI cascade to stop propagating past a single
Task-Supervised escape. #3 + #4 are the "no future leaks" gates the
audit test in stage 3 codifies.

## Follow-ups (out of scope for task 019f3440)

* Pre-existing `Platform.Agents.SystemEventSchedulerTest.DispatchTest
  — historian instruction content` flake. This one predates the
  cascade and is NOT fixed as part of this task. Stage 4 will
  document it here with a final baseline count once the fix is
  verified.

## Stage 4 — full-suite verification (`d3155071`)

`mix ecto.reset && mix test` on the worktree at `d3155071` (stage 3
audit test HEAD, three commits above main `b3339a24`):

| Run | Total | Failures | Skipped | Excluded |
|---|---|---|---|---|
| 1 | 5006 | 2 | 3 | 2 |
| 2 | 5006 | 2 | 3 | 2 |
| 3 | 5006 | 1 | 3 | 2 |

Exact numeric baseline: **`5006 tests, 0-2 failures, 3 skipped (2 excluded)`**.
Excluded tags are `[:files_service, :cascade_repro]` — the latter is
this task's stage-1 repro test, held out of default `mix test` per
`test_helper.exs`. Skipped count of 3 matches the pre-cascade baseline
noted in the stage 3 report.

Compared to the pre-cascade baseline (`b3339a24`: 4,618 tests / 1
failure), post-fix suite is 5,006 tests (+388, from PRs merged into
main during the fix window) with **zero cascade-driven failures**.

**Verified: `d9307abf`** (stage 2's fix commit — router→Roles seam
`try/rescue DBConnection.OwnershipError` guard + summarizer.ex:213-218
rescue reshaped so second `fail_transcript` cannot escape) *plus*
`d3155071` (stage 3 audit test).

**Cascade fully closed. Pre-cascade baseline restored.**

### Residual failures — all pre-existing, unrelated to cascade

Each of these failures reproduces on `b3339a24` (last-known-green
baseline) and is untouched by this task's stage 1-3 commits.

1. **`Platform.Tasks.ProjectTest — create_project/1 does NOT broadcast
   on insert failure`** (`test/platform/tasks/project_test.exs:82`)
   — pre-documented flake #1 from stage 3 report. Stale PubSub
   subscription leaks from sibling case → `refute_receive` catches
   another test's broadcast.
2. **`Platform.TenancyTest — denylist overlay + ops API
   promote_to_admin/2 emits a role_change audit event`**
   (`test/platform/tenancy_test.exs:889`) — variant of pre-documented
   flake #2 (audit event ordering race). Same underlying
   `vault.credential.revoked` vs `role_change` telemetry ordering
   race, on promote_to_admin/2 rather than revoke_admin/2.
3. **`Platform.Execution.LocalRunnerTest — LocalWorkspace git worktree
   setup_git_worktree ...`** (`test/platform/execution/local_runner_test.exs:339`
   and `:362`) — pre-existing test-file-local flake. Test uses
   `/tmp/wt-idempotent-<pid>/` paths that collide when the test file
   is retried without cleanup. Last touched on main at `43d95926
   fix: stabilize flaky credential lease env injection test` (weeks
   before this task); the fix apparently didn't address the worktree
   collision. Not in the stage 3 report because stage 3's isolation
   run didn't happen to hit it.
4. **`Platform.MeetingsTest — verify_livekit_jwt/2 (task 019f3312
   stage 2) returns {:error, :bad_signature} when HS256 doesn't
   verify`** (`test/platform/meetings_test.exs:606`) — pre-existing
   HS256 signature test flake introduced by PR #483 (`b3339a24`, part
   of the pre-cascade baseline). Tampered token occasionally passes
   verification when the test's random-secret setup races with the
   JWT decode step. Not in the stage 3 report for the same reason as
   #3.

None of these four are new. None are triggered by the cascade-fix
commits (stage 1 repro, stage 2 rescue guards, stage 3 audit test).
The task's touched files (`summarizer.ex`, `task_router_watcher.ex`,
`router.ex`, `data_case.ex`, `test_helper.exs`, plus new regression
tests) do not intersect any of the four failing tests' code paths.

### Historian scheduler flake — no longer reproduces at HEAD

The pre-existing `Platform.Agents.SystemEventSchedulerTest.DispatchTest
— historian instruction content` flake mentioned in the stage 3
report and above did **not** reproduce during stage 4 verification.
Five back-to-back runs of the isolated describe block all passed:

```
$ for i in 1..5; do mix test test/platform/agents/system_event_scheduler_test.exs \
    --only "describe:historian instruction content"; done
2 tests, 0 failures (32 excluded)   # ×5
```

The full file (34 tests, previously 42) also passed in isolation.
This flake was likely masked by the router-→Roles seam OwnershipError
raise during the stage 3 fork point (agent responder load_context/1
runs under Task.Supervised and would have raised → digest generation
returned degraded content). With stage 2's rescue in place, the
digest path completes deterministically.

## Follow-up ticket needed

- `Platform.Agents.SystemEventSchedulerTest.DispatchTest` —
  historian instruction content
  - Was pre-existing at `3cf980af` (before cascade); flaked 1/42
    deterministically in isolation.
  - No longer reproduces at `d3155071` (stage 3 HEAD).
  - Non-blocking. Keep this note as a bookmark in case it returns.
  - Recommended follow-up task: "Historian scheduler test content
    flake — confirm masking hypothesis or file bug." Backlog,
    priority low.

- `Platform.Execution.LocalRunnerTest — LocalWorkspace git worktree`
  test-file-local flake (item 3 above).
  - Reliably reproduces (not intermittent) — `/tmp/wt-*` collisions
    between test cases inside the same file.
  - Recommended follow-up: "LocalRunnerTest worktree /tmp path
    uniqueness — namespace by test PID + unique_integer, tear down
    between tests." Backlog, priority low.

- `Platform.MeetingsTest — verify_livekit_jwt HS256` flake (item 4).
  - Recommended follow-up: "verify_livekit_jwt HS256 tampered-token
    flake — pin secret before decode call." Backlog, priority low.

- `Platform.Tasks.ProjectTest` / `Platform.TenancyTest` audit +
  broadcast flakes (items 1-2).
  - Already documented; recommended follow-up: "Isolate telemetry
    audit-event ordering flakes in DataCase." Backlog, priority low.
