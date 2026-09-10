# ConnCase sandbox ownership: what this fixed, what it only narrowed

Task `01a089ee`. Branch `task/01a089ee-6af7-7001-b8d0-67de15f5f626`, merge-base
`ccb93cb4`. Everything below was measured, natively, on this branch.

## Read this first

**The migration closes the deterministic `on_exit` hole only in shared mode —
the 168 `async: false` files plus the 2 unflagged ones. The racy defect this
ticket was commissioned to fix lives entirely in the 16 `async: true` files.
Those two sets are disjoint.** The plan conflated them because in shared mode
the two properties coincide: the same change that keeps the connection alive
for `on_exit` also keeps it alive for an in-flight writer. In manual mode they
come apart, and only the weaker of the two is bought.

**The async orphan still detaches the audit telemetry handler after the
migration.** Measured on both trees, identically — see §4. `SandboxHelpers`'
drain is shared-mode-only by design, so nothing waits for an `async: true`
orphan before or after this change. `start_owner!/2` lengthens the window
before the connection dies; it does not remove the tear-down.
**That residual needs its own ticket.** It is not addressed here and a green
suite must not be read as closing it.

Two further things are true and both belong in this paragraph, not at the end:

* Stage 1's originally specified `async: true` case — an `on_exit` that does a
  *direct* `Repo` read and succeeds — **is unsatisfiable by this fix, and not
  through any fault of the fix.** ExUnit runs `on_exit` in a separate process
  that is neither owner nor allowed and that inherits no `$callers`, so in
  manual mode a `Repo` call from `on_exit` raises `DBConnection.OwnershipError`
  regardless of who owns the connection — red before the migration and red
  after. Verified two ways: a probe under `Platform.DataCase, async: true`
  (which has used `start_owner!` since task `019f9d80`) fails identically, and
  the same conclusion was derived independently from the decompiled
  `ExUnit.OnExitHandler`. The hole belongs to ExUnit's `on_exit` runner, not to
  ConnCase.
* The migration is still worth having. It converges ConnCase onto the shape
  `Platform.DataCase` already proved, removing a divergence rather than adding
  one, and it makes real several `on_exit` callbacks that were silently dead.
  `test/security/external_attachment_scope_test.exs`'s drain was, in the
  words of the stage that read it, "a no-op wearing a rationale" — the comment
  said it mirrored DataCase's drain, and the `GenServer.call` inside it could
  never have reached a live connection.

## 1. The change

`test/support/conn_case.ex`'s `setup` moved from

    :ok = Sandbox.checkout(Repo)
    unless tags[:async], do: Sandbox.mode(Repo, {:shared, self()})

to the `start_owner!` / `stop_owner` shape `data_case.ex` already used: the
connection is owned by a separate agent process that outlives the test process
and the whole `on_exit` chain, with `Sandbox.allow(Repo, owner, self())` on the
shared branch and `Sandbox.stop_owner(owner)` last.

**Correction, recorded so it is not repeated.** A claim circulated during
planning that `conn_case.ex:49` shared the sandbox unconditionally, diverging
from DataCase. **That is false.** On `origin/main` the
`Sandbox.mode(Repo, {:shared, self()})` call sat inside `unless tags[:async] do`.
ConnCase and DataCase already agreed on sharing policy. The only divergence
was checkout-vs-`start_owner!`.

## 2. Counts, re-derived

Anchored on the `use` directive at the start of a line, at the merge-base
`ccb93cb4`:

    ^[[:space:]]*use PlatformWeb.ConnCase          186
                              , async: true         16
                              , async: false       168
                              (no flag)              2   page_controller_test.exs,
                                                         auth_controller_test.exs
                              parts sum:           186  ✓

    loose  grep -rl "PlatformWeb.ConnCase"         188

**The plan's 187 / 169 is wrong.** The error source is the loose grep: at 188
it counts two files that merely *mention* the directive in prose rather than
using it, and they are nameable —

* `test/support/conn_case.ex` itself, whose moduledoc says "you can even run
  database tests asynchronously by setting `use PlatformWeb.ConnCase, async: true`";
* `test/platform/meetings/intent_queue/mirror_fatality_test.exs`, which names
  the directive in a comment.

The `16` is right, and it is the number that scopes the defect. Stage 2's
executor re-derived 186 / 16 / 168 / 2 independently and got the same.

The same trap applies to the `async: true` count on its own. A loose
`grep -rl 'use PlatformWeb.ConnCase, async: true' test` at branch HEAD returns
**19**, not 16: `conn_case.ex`'s moduledoc sentence above is one of them, and
the two files this task added account for the other two. Anchor on
`^[[:space:]]*use`, and subtract this task's own files, before comparing
against anything.

At branch HEAD the same greps give 188 total / 18 `async: true` / 169
`async: false` / 2 bare, whose parts sum to **189, not 188**. That is not a
miscount and is not averaged away: `conn_case_owner_lifecycle_test.exs`
declares two modules in one file, one `async: true` and one `async: false`, so
a file-level grep counts it in both buckets. The delta from the merge-base is
exactly the two files this task added.

**Test counts are approximate and are not a measurement.** The plan's
`~3216 tests / ~622 async` figures were never verified. Counting test
declarations by grep (`^[[:space:]]*(test|property)[ (]`) over the merge-base
ConnCase set gives **3237 across all ConnCase files and 622 in the 16
`async: true` ones**. That method cannot see tests generated in a loop and can
over-count declarations inside commented-out blocks, so treat both as
order-of-magnitude only. The 622 happens to match the plan's figure; the
3237 does not match its 3216, and neither number was produced by ExUnit.

## 3. The deterministic half, verbatim

`test/platform_web/conn_case_owner_lifecycle_test.exs`, three cases. On the
migrated tree: **3 tests, 0 failures, EXIT=0.** With *only* `conn_case.ex`
restored to the pre-migration `Sandbox.checkout(Repo)` shape (restored by
`cp`, never `git checkout --`): **3 tests, 3 failures, EXIT=2.**

Failure 1 — manual mode (`async: true`), a survivor allowed on the connection:

    1) test a survivor allowed on the connection can still read during on_exit (manual mode)
       (PlatformWeb.ConnCaseOwnerLifecycleAsyncTest)
       test/platform_web/conn_case_owner_lifecycle_test.exs:92
       ** (exit) exited in: GenServer.call(#PID<0.478.0>, {:get, ...}, 5000)
           ** (EXIT) an exception was raised:
               ** (DBConnection.OwnershipError) cannot find ownership process for
       #PID<0.478.0> (:proc_lib) using mode :manual.
       ...
       stacktrace:
         (elixir 1.19.5) lib/gen_server.ex:1142: GenServer.call/3
         test/platform_web/conn_case_owner_lifecycle_test.exs:118: anonymous fn/2 in ...
         (ex_unit 1.19.5) lib/ex_unit/on_exit_handler.ex:140: ExUnit.OnExitHandler.exec_callback/1
         (ex_unit 1.19.5) lib/ex_unit/on_exit_handler.ex:126: ExUnit.OnExitHandler.on_exit_runner_loop/0

Failure 2 — shared mode (`async: false`), a direct `Repo` read from `on_exit`:

    2) test an on_exit callback can still read the Repo (shared mode)
       (PlatformWeb.ConnCaseOwnerLifecycleTest)
       test/platform_web/conn_case_owner_lifecycle_test.exs:46
       ** (exit) exited in: DBConnection.Holder.checkout(#PID<0.483.0>, [... repo: Platform.Repo ...])
           ** (EXIT) shutdown: "owner #PID<0.482.0> exited"
       stacktrace:
         (db_connection 2.9.0) lib/db_connection/holder.ex:99: DBConnection.Holder.checkout/3
         ...
         (ecto 3.13.5) lib/ecto/repo/queryable.ex:171: Ecto.Repo.Queryable.one!/3
         test/platform_web/conn_case_owner_lifecycle_test.exs:54: anonymous fn/1 in ...
         (ex_unit 1.19.5) lib/ex_unit/on_exit_handler.ex:140: ExUnit.OnExitHandler.exec_callback/1
         (ex_unit 1.19.5) lib/ex_unit/on_exit_handler.ex:126: ExUnit.OnExitHandler.on_exit_runner_loop/0

Failure 3 — shared mode, a survivor: same `** (EXIT) shutdown: "owner
#PID<0.485.0> exited"`, reached through `GenServer.call/3` rather than directly.

In every case the `refute Process.alive?(test_pid)` guard passed *first*, so
the failure is located at the `Repo` call and names the mechanism rather than
the symptom. Full capture: `~/oct_evidence_01a089ee/stage1_RED.txt`. The stage-4
re-run reproduced all three (the line numbers cited above are the stage-4
re-run's; stage 1's capture differs by one line in failure 3).

Note what failure 1 shows and does not show. The manual-mode case asserts the
property the migration *does* change there — a process that was **allowed** on
the connection and that outlives the test body can still use it during
`on_exit`, because the owner agent is still alive. It does **not** show that
`on_exit` itself can reach the Repo in manual mode; it cannot, before or after
(see §Read this first).

## 4. `:telemetry.list_handlers/1`, both trees — the centrepiece

`test/platform_web/conn_case_supervised_orphan_test.exs` builds the racy half
deliberately: an `async: true` ConnCase test starts a child under
`Platform.TaskSupervisor` (which seeds `:"$callers"`, so
`DBConnection.Ownership.Manager.proxy_for/2` resolves an owner by walking that
chain) and the child's synchronous `Platform.Audit` write is still parked in
`DBConnection.Holder.checkout` when the owner goes away. Pass/fail rests on
`:telemetry.list_handlers/1` for the handler id `"platform-audit-telemetry"`
and on the *class* of the arriving failure. There is deliberately no assertion
in that file that counts audit rows or downstream failures — that would measure
the VM-wide detach cascade, the amplifier, not the defect.

**Measured, for handler id `"platform-audit-telemetry"` on the event the
orphan emits:**

| shape  | tree                                   | attached BEFORE | attached AFTER |
|--------|----------------------------------------|-----------------|----------------|
| QUEUED | PRE-migration (`Sandbox.checkout/1`)   | **true**        | **false** — DETACHED |
| QUEUED | POST-migration (`Sandbox.start_owner!/2`) | **true**     | **false** — DETACHED |
| LATE   | PRE-migration (`Sandbox.checkout/1`)   | **true**        | **true** — still attached |
| LATE   | POST-migration (`Sandbox.start_owner!/2`) | **true**     | **true** — still attached |
| QUEUED-BEYOND-DRAIN | POST + stages 1–2, drain forced to time out | **true** | **true** — detached, then repaired inside `execute/3` |
| QUEUED-DRAINED | POST + stages 1–2, drain allowed to finish | **true** | **true** — never detached at all |
| LATE   | POST + stages 1–2                      | **true**        | **true** — unchanged, still rescued |

**Identical on both trees. The migration does not close the async hole** — the
two remedies in task `01a08b49` do, and the last three rows are that result.
Note that `attached AFTER` reads **true** on every one of those rows, including
one where the handler really was detached: once stage 1's guardian repairs a
detach from inside `:telemetry.execute/3`, this column stops discriminating and
is no longer the measurement. See "What stages 1–2 changed" at the end of this
section for the readings that replaced it.

The mechanism, classified in-process rather than inferred. The queued orphan's
raw failure:

    {:exit, {{:shutdown, %DBConnection.ConnectionError{
        message: "owner #PID<0.2575.0> exited\n\nClient #PID<0.2578.0> (Task.Supervised)
                  is still using a connection from owner at location: ...
                  (db_connection 2.9.0) lib/db_connection.ex:1747:
                  DBConnection.run_transaction/4 ...",
        severity: :error, reason: :error}},
      {DBConnection.Holder, :checkout, ...}}}

and `:telemetry`'s own line, once per run:

    [error] Handler "platform-audit-telemetry" has failed and has been detached. Class=:exit

An **exit** is what escapes `persist_or_skip/4` — its `rescue` clauses catch
every raise, and its refusal to `catch :exit` is deliberate and documented at
`lib/platform/audit/telemetry_handler.ex`. That refusal stands and was not
touched.

**The LATE shape does not reproduce the defect, on either tree.** A child that
sleeps past the end of the test and only then writes finds the ownership table
no longer resolving its caller, so it raises `DBConnection.OwnershipError`,
which `persist_or_skip/4` **rescues**, and the handler survives. "A late orphan
detaches the handler" is the intuitive theory and it is false. The write must
be **in flight**, not late. Reproduction record: QUEUED, 10 attempts, 10
detaches, 0 misses (plus 5 POST and 3 PRE committed-file runs, all EXIT=0);
LATE at 25 ms / 250 ms / 500 ms, 12 attempts across both trees, 0 detaches.
The stage-4 re-run reproduced both rows of each shape.

The file restores the handler four times over (the guardian first, since stage
1) and asserts each restore, because absent a repair the detach is VM-global and
permanent for the rest of the run. **Known residual, stated rather than
hidden:** between `:telemetry`'s internal detach and the first re-attach there
is a sub-millisecond VM-global window in which a concurrently scheduled async
test could emit an audited event and find no listener. Stage 1's guardian
narrows that window from "the rest of the run" to one synchronous `execute/3` on
the failure event; it does not remove it. It is inherent to measuring the real
handler id rather than a stand-in, and it is the same window the actual defect
opens. Observed cost in a full concurrent run: 0 failures across 16 377 tests,
with exactly 1 detach.

### What stages 1–2 changed, and which half of the defect each one closes

The defect has two halves and they are closed by different changes. Stating them
separately matters because each remedy is silent about the other's half:

* **The lost audit row** — closed by stage 2's `$callers`-scoped drain
  (`SandboxHelpers.await_own_supervised_writes/2`, called from
  `PlatformWeb.ConnCase`'s `async: true` teardown before
  `Sandbox.stop_owner/1`). The orphan is waited for, its queued write is
  **served**, and the row is written. There is no orphan left to kill, so
  nothing reaches `:telemetry` and no detach occurs at all.
* **The blast radius** — closed by stage 1's `Platform.Telemetry.HandlerGuardian`,
  which re-attaches the handler from inside `[:telemetry, :handler, :failure]`.
  This runs before `:telemetry.execute/3` returns and before `:telemetry` logs
  its `Class=:exit` line (`deps/telemetry/src/telemetry.erl`: `detach/1` at 205,
  the failure event at 213, the log at 214). It does **not** save the write — the
  row is still lost — it bounds who else is harmed.

The scoped drain removes the orphan and so saves the row; the guardian bounds
the detach and so saves the run. Neither substitutes for the other, which is why
`conn_case_supervised_orphan_test.exs` now carries both a QUEUED-DRAINED case
(drain allowed to finish) and a QUEUED-BEYOND-DRAIN case (drain forced to time
out via `@tag sandbox_drain_timeout:`), differing in exactly that one variable.

**Re-measured in the original units** (task `01a08b49` stage 3, Mac mini,
`PLATFORM_TEST_DATABASE=platform_test_01a08b49_s3`, the whole file at 20 distinct
seeds — 1–10 and 11–20):

| case | attempts | left DETACHED at `execute/3` return | write outcome |
|------|----------|-------------------------------------|---------------|
| QUEUED-DRAINED | 20 | **0** | `:inserted` — the row survives |
| QUEUED-BEYOND-DRAIN | 20 | **0** (was 10 of 10) | `{:exit, _}` — row still lost |
| LATE | 20 | 0 | `{:raise, DBConnection.OwnershipError, _}`, rescued |

Against the original reproduction record of QUEUED **10 attempts / 10 detaches /
0 misses**, the queued shape now leaves the handler detached **0 times out of 20**.
That is the guardian's result and it holds for both queued cases. It is NOT by
itself evidence that the drain works: in QUEUED-BEYOND-DRAIN the detach still
happens and is merely repaired, which is why the restore counter and the write
outcome are reported beside it. Exactly **one** `Class=:exit` line appears per
run — from the beyond-drain case, by design — and exactly one
`[SandboxHelpers] N supervised child(ren) started by #PID<…> still running`
warning, which is the positive control that its drain was genuinely bypassed
rather than the case having quietly degraded into the drained one.

**Instrument note, measured the hard way.** `HandlerGuardian`'s restore counter
is BEAM-global per handler id and cannot attribute a detach to a particular
emission, so it is usable on BEYOND-DRAIN (the only case that detaches on the
unmutated tree) but not on DRAINED. `Sandbox.stop_owner/1` returns **before** the
`{:shutdown, %DBConnection.ConnectionError{}}` exits have propagated to the
orphans, so a detach can land after its own test's teardown has finished and
inside a sibling test's sampling window; ExUnit shuffles test order within a
module by seed, so it is seed-dependent. With a `delta == 0` assertion on
DRAINED the file was green 4 of 10 seeds and red 6 of 10, each red run reporting
delta 1 while the same run's write outcome read `:inserted` — contradictory for a
real drain failure. With the sibling skipped it was green 10 of 10. DRAINED is
therefore decided on the write outcome (`:inserted`), which is process-local and
is the outcome stage 2 exists to produce.

### What neither remedy does

* A process **`:kill`ed** between `:telemetry`'s internal detach and the failure
  event is still unrepaired. The guardian runs *from* the failure event, so a
  process that never reaches it leaves the handler detached, and no drain helps
  because the write was already in flight.
* **Bare-`spawn` writers** (task `01a06638` / PR #965) are invisible to both
  drains **by construction**. They carry no `:"$callers"`, so they never resolve
  an owner and an ownership-scoped drain cannot see them. This is not a gap to
  be closed in `SandboxHelpers`; it is a different defect with a different fix.
* `Platform.DataCase`'s `async: true` branch has the identical hole and is
  **flagged, not fixed** — stage 2 deliberately left it alone.

## 5. Does any ConnCase test rely on the test process being the connection OWNER?

**No. Zero RELIES-ON-OWNER sites.** This was answered by reading, not by
grepping — a grep for `Sandbox.allow` gives a confident wrong answer by missing
implicit dependence.

The reason is checkable and is the load-bearing part of the answer:
`DBConnection.Ownership`'s `owner_allow/5` **inserts the allowed pid into the
same ETS table that `proxy_for/2` reads**
(`deps/db_connection/lib/db_connection/ownership/manager.ex:24-27`). `$callers`
resolution therefore cannot distinguish an owner from an allowed process — so
"was the test process the owner, or merely allowed?" is a distinction no
resolving code path can observe. The only APIs that *can* observe it are
`Sandbox.allow/3`'s `owner_or_allowed` parent argument (satisfied in both modes
by the explicit `Sandbox.allow(Repo, owner, self())` the migration adds) and
`stop_owner/1`.

Sites, with a verdict each.

The 16 `async: true` ConnCase files at the merge-base:

| file | verdict |
|---|---|
| `platform_web/controllers/error_html_test.exs` | NO RELIANCE — no process start, no `Sandbox.*` |
| `platform_web/controllers/error_json_test.exs` | NO RELIANCE — same |
| `platform_web/controllers/github_webhook_ci_scoping_test.exs` | NO RELIANCE — same |
| `platform_web/controllers/github_webhook_controller_test.exs` | NO RELIANCE — same |
| `platform_web/controllers/github_webhook_delivered_but_open_test.exs` | NO RELIANCE — same |
| `platform_web/controllers/github_webhook_multi_repo_test.exs` | NO RELIANCE — same |
| `platform_web/controllers/livekit_webhook_controller_test.exs` | NO RELIANCE, and **FIXED BY MIGRATION** — its summarizer stragglers outlive the test body and previously lost the connection with the test process |
| `platform_web/controllers/meeting_calendar_controller_test.exs` | NO RELIANCE — no process start, no `Sandbox.*` |
| `platform_web/live/control_center/add_agent_to_space_picker_test.exs` | NO RELIANCE — starts a LiveView via `live/2`; `Phoenix.LiveViewTest` seeds `$callers`, which resolves against owner-or-allowed alike |
| `platform_web/live/meeting_bar_live_test.exs` | NO RELIANCE — no process start, no `Sandbox.*` |
| `platform_web/live/meeting_live_project_scope_test.exs` | NO RELIANCE — `live/2` only, as above |
| `platform_web/live/meeting_live_test.exs` | NO RELIANCE — `live/2` only |
| `platform_web/live/skills_live_project_scope_test.exs` | NO RELIANCE — `live/2` only |
| `platform_web/live/tasks_live_project_scope_test.exs` | NO RELIANCE — `live/2` only |
| `platform_web/route_resume_test.exs` | NO RELIANCE — no process start, no `Sandbox.*` |
| `platform_web/theme_toggle_test.exs` | NO RELIANCE — `live/2` only |

Non-async ConnCase files that call `Sandbox.*` or start a process — the only
places where the owner/allowed distinction could bite. Re-derived at stage 4
with the predicate `Sandbox.` | `start_supervised` | `Task.Supervisor.` |
`GenServer.start` | `spawn(` | `spawn_link(` | `Agent.start`, which returns
**three** files:

| file | verdict |
|---|---|
| `test/security/external_attachment_scope_test.exs:55` | NO RELIANCE, and **FIXED BY MIGRATION**. Calls `Sandbox.allow(Repo, self(), pid)` — `self()` remains a valid `owner_or_allowed` parent because the migration explicitly allows the test process in shared mode. Its `on_exit` drain at `:58-68` was previously dead and now runs against a live connection. |
| `test/platform_web/live/shell_live_test.exs:1367,1760,1871,2310` | NO RELIANCE. `start_supervised(MeetingState)` is linked to the test's supervisor and dies with the test; the `spawn_link` at `:2310` registers in `Platform.Agents.Registry` and never touches `Repo`. |
| `test/platform/tasks/stack_deploy_integration_test.exs:47` | NO RELIANCE. `Agent.start_link/2` holds an in-memory stub map; no `Repo` call. |

**Discrepancy, reported rather than averaged:** stage 2 recorded "4
`async: false` ConnCase files that call `Sandbox.*` or start a process"; the
stage-4 re-derivation with the predicate above finds **3**. The two
FIXED-BY-MIGRATION sites and the zero RELIES-ON-OWNER verdict agree between the
two passes; only the size of the swept set differs, most likely from a wider
process-starting predicate in stage 2. Either way the answer is a handful of
sites, not a large set, so this ticket was not mis-sized.

## 6. Suite

Branch, full `apps/platform` suite, stage 4, run natively from `apps/platform`
against a private `PLATFORM_TEST_DATABASE`:

    Finished in 454.7 seconds (44.8s async, 409.8s sync)
    27 doctests, 16377 tests, 0 failures, 3 skipped (9 excluded) — EXIT=0

ExUnit prints no `invalid` counter when there are none, i.e. **0 invalid** —
worth stating, because `0 failures, N invalid` still exits 0 and a raising
`setup_all` silently skips whole modules.

Merge-base `ccb93cb4` baseline, same scope (stage 2, separate worktree, private
`PLATFORM_TEST_DATABASE`, launched concurrently so both saw the same machine
load):

    27 doctests, 16371 tests, 0 failures, 3 skipped, 9 excluded, 0 invalid — EXIT=0

Both failure sets are **empty**, so the branch set contains no test name absent
from the baseline set. The `+6` test delta is exactly the six tests this task
added (3 lifecycle + 3 orphan). No failure needed attributing to
`LocalRunnerTest`'s 500 ms `assert_eventually` flake, because there were none.
`mix format --check-formatted` exits 0 and was
run as a separate step, natively from `apps/platform` — the plan's worry that
the formatter might not run applies to a containerised environment that does
not exist on this box.

## 7. Explicitly OUT OF SCOPE

Recorded so a future reader does not think these were considered and rejected.
None of them was attempted.

* **Converting any of the 168 `async: false` ConnCase files to `async: true`.**
  ConnCase is 9 % async where DataCase is 21 %, and the safer template may make
  some of the serialised files no longer need serialising. That is a
  **follow-up ticket**, deferred, not foreclosed. Note before anyone picks it
  up: §4 says the async orphan hole is open, so a conversion moves a file *into*
  the unprotected set.
* **Relaxing `persist_or_skip/4` to `catch :exit`**
  (`lib/platform/audit/telemetry_handler.ex`). Its refusal is deliberate and
  documented for the high-volume historian path; catching the exit would convert
  "an audit write was destroyed and a pooled connection was force-reconnected"
  into silence. The file is unchanged on this branch.
* **Widening, or adding an exemption to,
  `test/platform/regression/supervised_task_repo_audit_test.exs`.** Every entry
  in its exemption block is a place the audit has agreed not to look. No entry
  was added and no regex widened; the file is unchanged.
* **The bare-`spawn` family, task `01a06638` / PR #965.** A different and
  **inverse** defect: those sites set no `$callers`, never resolve an owner, and
  are invisible to the drain — whereas the orphan in §4 reaches the connection
  *because* `$callers` resolves. Fixing either would not touch the other. No
  bare-spawn site was touched.

## 8. The open ticket this leaves

The `async: true` supervised-orphan detach (§4). The hazard worth filing is not
the orphan itself but the **blast radius**: one orphaned task detaches
`"platform-audit-telemetry"` for the entire VM, permanently for the rest of the
run, and every subsequent audit assertion then fails for a reason unrelated to
what it was testing. A handler whose failure mode is global is a poor fit for a
suite that runs work concurrently. Whether it should be re-attachable, scoped
per test, or whether `async: true` ConnCase tests should be prevented from
leaving supervised children behind at all, is the real question — and it is
open, not answered here.

**RESOLVED by task `01a08b49`, and the answer was two of the three options §8
listed, not one.** "Re-attachable" was taken by stage 1's
`Platform.Telemetry.HandlerGuardian` (blast radius) and "scoped per test" by
stage 2's `$callers`-scoped drain (§9, the lost row). The third option —
preventing `async: true` ConnCase tests from leaving supervised children behind
— was NOT taken, and deliberately so: the drain waits for such children rather
than forbidding them, which is why
`conn_case_supervised_orphan_test.exs` can still construct the un-drained shape
on demand via `@tag sandbox_drain_timeout:`. The paragraph above is left as the
dated record of what was open at the time. See §4, "What stages 1–2 changed",
for which half each remedy closes and for what neither of them does.

## 9. Closed by task `01a08b49` stage 2 — a `$callers`-scoped drain

§8 asked whether `async: true` ConnCase tests "should be prevented from leaving
supervised children behind at all". They are now, and the mechanism is the third
option §8 listed: **scoped per test**.

`Platform.SandboxHelpers.await_own_supervised_writes/2` polls
`Task.Supervisor.children(Platform.TaskSupervisor)` and keeps only the pids whose
`:"$callers"` chain contains a given owner pid. `PlatformWeb.ConnCase`'s `async:
true` teardown calls it (via `drain_own_or_warn/2`) **before**
`Sandbox.stop_owner/1`, keyed on the test pid captured in `setup` — `on_exit`
runs in a different process, so `self()` there is not the test.

### The asymmetry that makes this admissible where §4's unconditional drain is not

The reason §4's residual looked unfixable was that draining ALL of
`Platform.TaskSupervisor` from an `async: true` case waits on concurrent modules'
children. That objection is about **the set**, not about draining. The mechanism
that creates the exposure is the mechanism that scopes the remedy:
`Task.Supervisor.start_child/2` seeds `:"$callers"` in the child, that entry is
*why* the child reaches the sandbox connection at all
(`DBConnection.Ownership.Manager.proxy_for/2` walks the caller list against the
ownership table), and the same entry says whose child it is.

`Platform.SandboxHelpersScopedDrainTest` pins the discrimination in both
directions, because "excludes everything" would satisfy a one-sided test and
would silently reinstate the defect. The exclusion case was written FIRST and
shown red against a naive unfiltered poller: it returned `{:timeout, 1}` after
200 ms where `:ok` is required. Ownership is the whole `$callers` chain, not its
head — a grandchild's chain contains the test pid with an intermediate child at
the head, and the real audit path is exactly that shape.

### CORRECTION to `Platform.SandboxHelpers`' moduledoc, and it mattered

Until this stage the moduledoc said that in `:manual` mode "a `Task.Supervisor`
child is not in the owner chain at all — it has no connection to protect, and
`Repo` calls from it raise `DBConnection.OwnershipError`". **The first half is
false.** `Ecto.Adapters.SQL.Sandbox.start_owner!/2` on its `shared: false` branch
calls `allow(repo, self(), parent)`, so the TEST process is an *allowed* process
even under `async: true`, and a `$callers`-chained child resolves that owner. Its
`Repo` calls succeed while the test is alive —
`PlatformWeb.ConnCaseSupervisedOrphanTest`'s positive control 2 asserts exactly
that from an `async: true` ConnCase case, and has been passing throughout. What
raises `OwnershipError` is a child reaching the Repo *after* the owner is gone,
which is a statement about timing and not about mode.

Why it mattered: that framing made the async case look like it had nothing to
protect, which is part of why §4's residual read as inherent. The surviving half
of the objection is intact and both refusal comments were amended rather than
deleted.

Also: `proxy_for/2` sits at `manager.ex:23-31` today, not the `:24-27` that three
comments in this tree cite. Cite the symbol.

### A drained write can still be lost — to DBConnection's queue budget

Wiring the drain does **not** simply make §4's queued orphan succeed. With the
tag removed, its failure class changes from `{:exit, "owner … exited"}` to
`{:raise, DBConnection.ConnectionError, "…request was dropped from queue after
493 ms…"}`. The drain holds the owner alive, but
`conn_case_supervised_orphan_test.exs`'s own `@blocker_hold_ms 3_000`
monopolises the single sandbox connection for longer than DBConnection's default
`:queue_target` 50 ms / `:queue_interval` 1000 ms, so the orphan is dropped from
the queue before it is ever served.

Consequence for any later "drained and written" case: **do not reuse a
multi-second blocker.** The write you expect to succeed will be starved by the
construction rather than served by the drain, and it will read as "the drain does
not work" — a clean measurement of the wrong quantity.

### Why `conn_case_supervised_orphan_test.exs` now tags itself

Once the drain exists by default, the un-drained shape cannot be constructed. The
per-test `@tag sandbox_drain_timeout: <ms>` seam (read in ConnCase's `setup
tags`; absent, the helper default of 5 000 ms applies) forces the timeout branch,
and under that forcing §4's readings are unchanged: same `{:exit, _}` class for
QUEUED, same rescued `OwnershipError` for LATE, same guardian restore-count delta
of 1. That the readings survive is the point — the defect is still there when
nothing waits.

### Counts, re-derived once more

Anchored on `^[[:space:]]*use`, there are **16** `async: true` ConnCase files at
`ccb93cb4`, confirming §2. The loose grep there returns **17**, not 19, and the
loose/anchored gap is exactly ONE file — this tree's own
`test/support/conn_case.ex` moduledoc sentence. 19 is a HEAD-tree number
(anchored 18; the two extra files arrived with #973).

### Mutations

* Drop the `$callers` filter → the exclusion case goes red (above).
* Drop the ConnCase call → nothing in the helper-level test file notices, because
  those tests call the helper directly. `conn_case_scoped_drain_test.exs` exists
  for that reason: it asserts an observable consequence of the CALL, and under
  the mutation reads `{:error, %DBConnection.OwnershipError{}}`. Note the shape —
  `Repo.query/2` RETURNS the ownership error rather than raising it, so a guard
  that only looks for a raise buries its own diagnosis.
* Make the timeout effectively infinite → three red, including both readings
  above, so the tag seam is reachable.

### Still not covered

`Platform.DataCase`'s `async: true` branch has the identical hole and is
untouched by this stage, which owns ConnCase only. And bare-`spawn` children
remain invisible to both drains **by construction** — see §7; that is the inverse
family and no ownership-scoped drain can reach it.
