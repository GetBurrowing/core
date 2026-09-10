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

**Identical on both trees. The migration does not close the async hole.**

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

The file restores the handler three times over and asserts each restore,
because the detach is VM-global and permanent for the rest of the run.
**Known residual, stated rather than hidden:** between `:telemetry`'s internal
detach and the orphan's re-attach there is a sub-millisecond VM-global window
in which a concurrently scheduled async test could emit an audited event and
find no listener. It is inherent to measuring the real handler id rather than a
stand-in, and it is the same window the actual defect opens. Observed cost in a
full concurrent run: 0 failures across 16 377 tests, with exactly 1 detach.

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
