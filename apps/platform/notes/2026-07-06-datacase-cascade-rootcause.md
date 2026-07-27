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

---

# 2026-07-27 — the guard that only covered `resolve_and_start/1`

Task: `019fa003-091a-7733-9c79-777e90264493`.

The "BELT" recommendation in this file's *Stage 2 priority* section
(guard `task_router_watcher.ex`'s `resolve_runtime_for_task/1`) was
taken, and it was not enough. This section records what it missed, why
a return-value guard structurally cannot cover it, and what replaced it.

## The gap

`Platform.Orchestration.TaskRouterWatcher` is a globally-supervised
singleton that `Platform.DataCase` allow-lists into **every** test.
`Sandbox.allow/3` binds it to whichever test won the race, so a
`{:task_created, _}` / `{:task_updated, _}` broadcast raised by test A
routinely arrives while the watcher is sitting on test B's connection.

Five hand-rolled `rescue DBConnection.OwnershipError` + `catch :exit, _`
pairs had accumulated in that module — `boot_reconcile/0`,
`resolve_runtime_for_task/1`, two inline blocks in the `:reconcile`
handler, `redispatch_for_runtime/1`, `safe_reconcile/0`. Each was added
reactively after a different crash. Every one of them guards a **Repo
call's return value**.

The path that was never covered has no Repo call to guard:

* `should_run?/1` is pure struct reads.
* `router_running?/1` is a bare `Registry.lookup`.
* The **STOP branch** of `evaluate_task/1` reaches `terminate_child`
  (and through the router's terminate, `LeaseManager.clear/1`) with
  **zero Repo calls**.

So no Repo-derived `:sandbox_unowned` signal ever reaches the code that
terminates a router and clears its lease. A guard shaped as "run the
query, degrade on ownership error" has nothing to degrade *on*.

## Why that is worse than a crash

The state this path mutates is **global and non-transactional**:

| state | table / process | undone by sandbox rollback? |
|---|---|---|
| Registry entry | `Platform.Orchestration.Registry` | no |
| supervised router process | `TaskRouterSupervisor` child | no |
| lease row | `:orchestration_lease_manager` ETS, `:named_table, :public` | no |

Nothing raises. The watcher acts on a row it cannot see, and the
end-of-test rollback leaves every one of those mutations in place for
the next test. That is the mechanism behind the failures that were
being written off as "the known TaskRouter flake" — a label that
described the symptom and hid the cause.

**The Registry snapshot discriminates; the ETS lease row does not.** On
this branch `TaskRouter.terminate/2` does not run on the
`stop_assignment/1` path (there is no `trap_exit` here — that is sibling
task `019fa06a`'s change), so an assertion written against the lease row
can pass for the wrong reason. Assert against the Registry.

## The fix: a precondition at the broadcast boundary

`handle_task_event/2` and `handle_runtime_reconnected/1` now gate on
`Platform.Orchestration.SandboxGuard` **before** any of the above is
reachable:

1. `SandboxGuard.connection_owned?/0` — can this process check a
   connection out of the Repo at all? Issues no SQL. Short-circuits to
   `true` off the sandbox pool, so a transient production pool timeout
   can never be read as "not owned"; the check is inert in production
   **by construction**, not by convention.
2. `SandboxGuard.row_visible?/2` — is the row this broadcast is about
   visible on the connection *this* process can see? Gated on
   `sandbox_pool?/0`, so it cannot run in production at all. This is
   deliberately cheaper than auditing all eleven `broadcast_board/1`
   call sites to prove none of them can fire before its transaction
   commits — and re-auditing on every new one.

Only past both does the handler run `evaluate_task/1`, and even then
inside `SandboxGuard.guarded/3`. That envelope is not what makes
today's paths safe (they each carry their own rescue); it is what makes
the **next** handler added below that line safe by default.

Declined work emits
`[:platform, :orchestration, :sandbox_guard, :dropped]` telemetry via
`SandboxGuard.record_drop/3`. This is load-bearing, not decoration: a
test for a guard can otherwise only assert that *nothing happened*,
which passes vacuously when the trigger never arrived — the exact
failure mode that let this defect survive. The drop log is `:debug`,
not `:warning`: under the sandbox a foreign-connection drop is the
guard working, and at `:warning` it would bury the log a real problem
needs.

## The new invariant

> **No handler in `TaskRouterWatcher` may touch
> `Platform.Orchestration.Registry`, `TaskRouterSupervisor`, or the
> `:orchestration_lease_manager` ETS table before the sandbox
> precondition in `handle_task_event/2` has passed.**

It is restated in the module's own `@moduledoc` so the next author
reads it in the file they are editing.

## Sleeps were hiding the assertions, not just slowing them

All 13 `Process.sleep/1` calls in `task_router_watcher_test.exs` are
gone, replaced by `TaskRouterWatcher.sync/0` (a `GenServer.call`, so it
is answered strictly after every message already in the mailbox) and by
`Platform.AsyncAssertions.assert_eventually/3` polls.

The control that makes this more than a tidy-up: with the watcher
`:sys.suspend`ed, the **original `Process.sleep` form passes with zero
failures** while the converted `sync/0` form fails. The sleeps were not
merely slow — they were asserting nothing.

One conversion that must not be "simplified" later:
`router_running?/1` is a `Registry.lookup`, and the Registry
unregisters off its **own** independent monitor of the router process.
Our `:DOWN` and the Registry's are unordered, so the registry entry
routinely outlives the process by a scheduler hop. Asserting once
immediately after `:DOWN` is itself a race — the poll is required.

## Retiring the "known TaskRouter flake"

That guidance was never a file in this repo (`git grep` finds no such
list on `origin/main`); it propagated through task briefs and org
memory, which is why it survived unexamined for so long.

**It is retired. After this fix, a TaskRouter-family failure in any run
is a signal to investigate, not a line item to excuse.** The settling
evidence for "this failure is not mine" is a control run on the
untouched tree in the **same load window** — never a remembered flake
list. Failing sets on this suite are reported by membership, not by
count: two full-suite runs at an identical seed here have produced
completely disjoint failing sets.

## The run matrix (stage 5)

A single green run proves nothing on this suite, so the evidence is a
matrix, not a run. All full-suite runs used an isolated
`PLATFORM_TEST_DATABASE` (fix: `platform_test_019fa003`, control:
`platform_test_019fa003_c5`) because `config/test.exs:15` points every
worktree at the shared `platform_test` and the concurrent ADR-0046
stack produces Postgrex `40P01` failures indistinguishable from app
flakes. Each control/fix pair ran **concurrently**, so both trees saw
the same load window. Box load was 4–20 throughout — inside the band
where timing assertions mean something.

* **control** = `origin/main` @ `4f19c47b`, untouched. This is the
  rebased branch point: the branch was rebased off `b19eee64` onto
  `4f19c47b` so that 019f9d80's audit fix is in *both* trees.
* **fix** = `task/019fa003` @ `854733ca` (five stage commits + the doc
  qualification below).
* **probe** = the temporary adversarial `async: true` module described
  further down, present in *both* trees for those rows.
* **fix-lib-only** = the fix tree with its four new test files held
  out, so the test count matches control exactly (8231). This row
  exists to separate "the lib change caused it" from "45 more
  concurrent tests caused it".

| run | tree | probe | tests | failing set (by membership) |
|---|---|---|---|---|
| ctl-s11 | control | no | 8231 | {} |
| ctl-s22 | control | no | 8231 | {} |
| ctl-s33 | control | no | 8231 | {TaskRouterTest — no-ack silence, silence + prior ack (`task_router_test.exs:964`)} |
| ctl2-s11 | control | no | 8231 | {Audit.TelemetryHandlerTest — historian namespace bridging, async dispatch} |
| ctl2-s22 | control | no | 8231 | {Tasks.TaskTest — require_approved_plan_for/2 non-execution transitions; ExternalAgents.EphemeralCredentialsTest — GenServer restart kills the table} |
| ctlp-s11 | control | **yes** | 8243 | {**TaskRouterTest — failed review stage bounces in_review → in_progress** (`:479`); **TaskRouterTest — safety-net fire, deadline in the past** (`:758`)} |
| ctlp-s22 | control | **yes** | 8243 | {MeetingLiveTest — caption bar absent when captions_visible=false (`:3883`)} |
| ctlp-s33 | control | **yes** | 8243 | {**TaskRouterWatcherTest — soft_delete_task/1 stops the running router inline**} |
| fix-s11 | fix | no | 8276 | {MeetingLiveTest — CC toggle persistence (`:3578`)} |
| fix-s22 | fix | no | 8276 | {MeetingLiveTest — caption bar absent (`:3883`)} |
| fix-s33 | fix | no | 8276 | {TaskRouterTest — no-ack silence, silence + prior ack (`task_router_test.exs:964`)} |
| fixp-s11 | fix | **yes** | 8288 | {MeetingLiveTest — CC toggle persistence (`:3578`)} |
| fixp-s22 | fix | **yes** | 8288 | {} |
| fixp-s33 | fix | **yes** | 8288 | {MeetingsTest — list_stalled_router_dispatches/1 empty list; MeetingLiveGuestInviteTest — non-host does not see Copy guest link} |
| fixlib-s11 | fix-lib-only | no | 8231 | {Audit.TelemetryHandlerTest — agents.historian namespace bridging, async dispatch} |
| fixlib-s22 | fix-lib-only | no | 8231 | {} |

Plus the orchestration directory alone on the fix tree, five distinct
seeds: `545 tests, 0 failures` at seeds 41, 42, 43, 44 and 45 — 5/5.

### TaskRouter-family tally

| tree | runs | family failures | which |
|---|---|---|---|
| control | 8 | 4 | `task_router_test.exs` ×3, `task_router_watcher_test.exs` ×1 |
| fix | 8 | 1 | `task_router_test.exs` ×1 |

`TaskRouterWatcherTest` — the file this task owns — is **0/8 on the fix
tree** and **1/8 on control**, and the one control failure
(`ctlp-s33`, *"soft_delete_task/1 stops the running router inline"*)
appeared only once the adversarial probe was added. The probe
reproducing a watcher failure on untouched `main` and never on the fix
tree is the matrix's load-bearing result.

### Verdict: NOT "fixed" by this stage's own gate — one named residual

The gate for this task is **zero** TaskRouter-family failures across
every fix-branch and adversarial run. The fix tree has exactly one:

> `Platform.Orchestration.TaskRouterTest` — *"no-ack silence (task
> 019f6791-c01b stage 2) silence + prior ack → :check_no_ack silent via
> ack clause (silence orthogonal)"*, `task_router_test.exs:964`,
> failing at `:978` with `** (MatchError) no match of right hand side
> value: {:error, :not_found}` on `:ok = LeaseManager.record_ack(task.id)`.

It is **not this change's regression** and the evidence is direct: the
identical test, at the identical line, with the identical MatchError,
failed on the **untouched control tree at the same seed in the same
load window** (`ctl-s33` and `fix-s33`). `task_router_test.exs` is
owned by task `019fa121`, is still on fixed `Process.sleep` in tranche
B, and this task must not edit it.

The disposition is therefore: **gate clean except
`task_router_test.exs`, which is owned by `019fa121`.** Sibling
`019fa121` stage 3 has landed `0fe94009` on `task/019fa121` converting
the *"failed review stage bounces task from in_review back to
in_progress"* test (their `:562`; it appears at `:479` on this
branch's base and failed here on **control**, `ctlp-s11`) — with
0/9 task-tree runs failing against 3/9 on their control. That branch
merges independently; it was deliberately NOT merged here, because
pulling a sibling's conversions in would make the two trees differ by
far more than this change and destroy the isolation the control run
exists to provide.

### Every non-family failure, individually named and matched

* **`MeetingLiveTest` / `MeetingsTest` / `MeetingLiveGuestInviteTest`
  cluster** (fix: 4 of 8 runs; control: 1 of 8). Every one fails the
  same way — `** (exit) exited in: Phoenix.LiveViewTest.live("/meetings/…")`
  → `GenServer.call(…, {:phoenix, :child_mount, …}, 5000)` → `time out`.
  The `/meetings/…` mount performs a LiveKit `CreateRoom` call that
  resolves `nxdomain` in this environment: **60–67 occurrences per run
  on BOTH trees** (`ctl` 61/67/64, `fix` 60/62/62). It is a
  load-sensitivity of that mount path, not a logic break.
  *Matched to control:* `MeetingLiveTest :3883` failed identically on
  the control tree (`ctlp-s22`).
  *Attributed away from the diff by experiment:* the `fix-lib-only`
  row holds the lib change and drops the four new test files so the
  test count equals control's 8231 — and the meeting cluster
  **disappears entirely** (0 of 2 runs) while control at the same
  seeds produced 3 failures. The trigger is concurrent test *volume*,
  not the guard.
* **`Audit.TelemetryHandlerTest` — "handle_event returns fast … (async
  dispatch)"** (fix-lib-only s11). Matched: the same test family failed
  on control at the same seed (`ctl2-s11`, historian namespace variant).
* **`Tasks.TaskTest` — require_approved_plan_for/2**, and
  **`ExternalAgents.EphemeralCredentialsTest` — GenServer restart kills
  the table** (`ctl2-s22`). Control-only; never seen on the fix tree.

`external_admission_notifier_test.exs:138` — flagged as
known-independent and fixed on main by `4f19c47b` — did **not** appear
in any of the 16 runs, post-rebase. Confirmed gone.

### The adversarial probe (deleted; reconstruct from here)

`test/platform/orchestration/zz_adversarial_probe_019fa003_test.exs`,
`use Platform.DataCase, async: true`, 12 tests, deleted at the end of
stage 5 because it is a probe and not a deliverable.

Six of the twelve are generated by a `for n <- 1..6` and each does:
create an `Agent`, `Tasks.create_task/1` with `status: "planning"`,
`assignee_type: "agent"`, `assignee_id: agent.id` (the
`should_run?/1 == true` shape), then `Tasks.update_task/3` for a title
touch (re-evaluate an already-running assignment), then
`Tasks.update_task/3` to `"blocked"` — which is the STOP branch, the
one that reaches `terminate_child` with zero Repo calls. The remaining
six churn adjacent shapes so the broadcast stream is not uniform: a
user-assigned `planning` task, an unassigned backlog task,
planning → in_progress → in_review, in_progress → done, a
`stack_pending` task, and a burst of eight `planning` creates on one
project. It asserts nothing about the watcher; it is a load generator,
and the measurement is whether the rest of the suite survives it.

`async: true` is the load-bearing part: `DataCase` runs an async file
in **manual** sandbox mode, which is precisely the mode in which the
globally-allow-listed watcher can be sitting on another test's
connection when the broadcast lands.

### Sibling coordination — is stage 1's primitive enough for `019fa06a`?

`019fa06a`'s failure is `CleanupGhostTasksTest` dying on a
`DBConnection.OwnershipError` raised from
`RuntimeSupervision.expire_stale_leases/2`
(`runtime_supervision.ex:449`). Assessment, so that task adopts rather
than reinvents:

* **`SandboxGuard.guarded/3` is the right primitive for that call
  site, and it is sufficient for the error shape.** It catches both
  shapes that site can produce — the `DBConnection.OwnershipError`
  raise and the owner-exited `:exit` that `rescue` cannot see — and
  emits the drop telemetry that lets a test assert the degradation
  *positively* instead of asserting that nothing happened.
* **The precondition half is NOT what `019fa06a` needs.**
  `connection_owned?/0` + `row_visible?/2` exist here because the
  watcher's unguarded path mutates Registry / supervisor / ETS state
  that the sandbox rollback does not undo. `expire_stale_leases/2`
  mutates via `repo.update_all` — transactional, and rolled back. So
  the return-value guard that was structurally wrong for the watcher
  is structurally right there.
* **One trap.** Wrapping only line 449 moves the raise two lines down:
  every caller (`current_lease_for_task/1`, `current_lease_for_stage/2`,
  `latest_lease_for_task/2`, …) follows `expire_stale_leases/2`
  immediately with a `Repo.one/2` on the same unowned connection.
  Guard the **public function body**, not the private helper, and pick
  a fallback that means "I could not read the lease" (`nil`) rather
  than one that means "there is no lease".

This task deliberately does not edit `runtime_supervision.ex` or the
audit telemetry handler: three tasks' diffs overlapping in one PR makes
none of them independently reviewable.
