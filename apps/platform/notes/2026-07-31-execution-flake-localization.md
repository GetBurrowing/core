# Localizing the `test/platform/execution/` flake (task 019fb978, stage 1)

**NO PRODUCTION CODE CHANGED IN THIS STAGE.** This note is the deliverable.

Base commit: `391204eb` (`origin/main`). The plan was written against `ccd72922`;
`git diff --name-only ccd72922..391204eb` touches **none** of the files reasoned about here,
so every file:line claim in the plan still resolves.

Measurement DB: `PLATFORM_TEST_DATABASE=platform_test_019fb978` (dedicated, created and
migrated for this task) on every run below.

---

## TL;DR — this ticket is two unrelated bugs, and the guard meant to fix one is now causing it

| # | Failure | Trigger | Evidence |
|---|---|---|---|
| 1 | Isolated `mix test test/platform/execution/`, ~1-in-3 | **Shared `/tmp` namespace collision** in `local_runner_test.exs`. Never touches the DB. | Measured 40% → **0%** under a control. Conclusive. |
| 2 | Full-suite, 1 failure per run | **212 sandbox-ownership violations per run**, 145 of them from `TaskRouterWatcher`. The visible failing test is a *downstream victim* of a poisoned connection, not the violator. | Reproduced; frames and counts below. |

These two share **no** mechanism. Filing them under one ticket is what let both survive.

And the headline correction: **`SandboxGuard`, the guard added to stop ownership errors, is
the frame inside 289 of them.** Its own preconditions are Repo calls. Detail in §6.

---

## 1. Bug 1 — the isolated flake is a `/tmp` collision

### 1.1 Verbatim failure (run 01 of 20)

```
Running ExUnit with seed: 254638, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

...13:53:15.207 [warning] [RunServer] run-8 context stale — runner missed ack SLA
..13:53:15.240 [warning] [RunServer] run-12 context stale — runner missed ack SLA
13:53:15.301 [error] [RunServer] run-12 context dead — runner presumed dead
.13:53:15.462 [warning] [RunServer] run-14 context stale — runner missed ack SLA
........error: remote origin already exists.
...error: remote origin already exists.
....error: remote origin already exists.
...........

  1) test LocalRunner.spawn_run/2 injects credential lease env into the child process (Platform.Execution.LocalRunnerTest)
     test/platform/execution/local_runner_test.exs:92
     Assertion with == failed
     code:  assert String.trim(File.read!(output_file)) == "test-token-#{run_id}"
     left:  ""
     right: "test-token-run-61"
     stacktrace:
       test/platform/execution/local_runner_test.exs:124: (test)

error: remote origin already exists.
......error: remote origin already exists.
..........................
Finished in 3.3 seconds (0.00s async, 3.3s sync)
65 tests, 1 failure
```

And the dominant signature, 7 of 9 failures (run 06), unedited:

```
  1) test LocalWorkspace git worktree setup_git_worktree creates a worktree from a local repo (Platform.Execution.LocalRunnerTest)
     test/platform/execution/local_runner_test.exs:339
     match (=) failed
     code:  assert {:ok, wt_path} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)
     left:  {:ok, wt_path}
     right: {:error,
             {:worktree_add_failed, 128,
              "Preparing worktree (checking out 'run-wt-48')\nfatal: 'run-wt-48' is already used by worktree at '/tmp/wt-idempotent-50/run-49/git'"}}
     stacktrace:
       test/platform/execution/local_runner_test.exs:347: (test)

  2) test LocalWorkspace git worktree setup_git_worktree is idempotent when called twice (Platform.Execution.LocalRunnerTest)
     test/platform/execution/local_runner_test.exs:354
     match (=) failed
     code:  assert {:ok, wt_path_1} = LocalWorkspace.setup_git_worktree(workspace, repo_path, branch: branch)
     left:  {:ok, wt_path_1}
     right: {:error,
             {:worktree_add_failed, 128,
              "Preparing worktree (checking out 'run-wt-60')\nfatal: 'run-wt-60' is already used by worktree at '/tmp/wt-root-62/run-61/git'"}}
     stacktrace:
       test/platform/execution/local_runner_test.exs:362: (test)
```

Read the two right-hand sides: the test with prefix `wt-root` collides with
`/tmp/wt-idempotent-50/`, and the test with prefix `wt-idempotent` collides with
`/tmp/wt-root-62/` — **each other's** directories. Within one VM that is impossible, since
each holds a distinct `System.unique_integer`. Those paths were written by a *different*
`mix test` process.

### 1.2 Raising frame and process

**Nothing raises.** No exception, no exit, no crash report. Both are ordinary ExUnit
assertion failures evaluated **in the ExUnit test process** — not in `TaskRouterWatcher`,
not in a `TaskRouter`, not in a `Task.Supervisor` child. Signature B is a *returned*
`{:error, {:worktree_add_failed, 128, …}}`; exit code 128 comes from the `git` child
process, not the BEAM.

### 1.3 Mechanism

`local_runner_test.exs` builds temp paths from a machine-global namespace plus a
**per-VM** counter:

```elixir
defp temp_dir(prefix) do
  path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  File.mkdir_p!(path)
  path
end

defp unique_run_id, do: "run-#{System.unique_integer([:positive, :monotonic])}"
```

`System.unique_integer/1` is unique within one BEAM and **restarts from a low value in
every new `mix test`**. `System.tmp_dir!()` is shared machine-wide. The product is not
unique: every run reissues `/tmp/git-repo-48`, `/tmp/wt-root-51`, `run-61`, and nothing ever
deletes them. Census on this box: `workspace-root: 776`, `no-cmd: 501`, `spawn-root: 450`,
`lease-env-root: 441`, `git-repo: 47`, `wt-root: 28`, `wt-idempotent: 26`.

Two observed consequences:

1. `setup_temp_git_repo/0` re-enters an existing repo — `git remote add origin` prints
   `error: remote origin already exists.`, visible in **every** run above including the
   green ones. That line is the collision announcing itself before it bites.
2. Stale worktree registrations survive. Observed directly, with no test running:

   ```
   $ cd /tmp/git-repo-48 && git worktree list
   /tmp/git-repo-48            38951ce [main]
   /tmp/wt-root-51/run-50/git  38951ce [run-wt-49]
   ```

   A later run landing on that repo and asking for `run-wt-49` gets exit 128 — signature B.

For signature A the collision truncates a file. The child is
`/bin/sh -c "printenv GITHUB_TOKEN > <output_file> && sync"` and `>` opens `O_TRUNC`.
`assert_eventually/2` (line 459) is sound — it `flunk`s on timeout — so its success at line
117 proves the file *was* non-empty; the empty read at 124 therefore requires a **second**
truncating open. Confirmed there is no product-side respawn: `LocalRunner.spawn_run/2`
calls `LocalProcessWrapper.start_link/1` once, and that module has exactly one `Port.open`
(line 99, in `init/1`), no retry path. The second writer is another VM that regenerated the
identical `run_id` — which is also why `right:` is `"test-token-run-61"` in both.

### 1.4 Control experiment — this is what makes it conclusive

| Arm | `TMPDIR` | Runs | Failing | Rate |
|---|---|---|---|---|
| Baseline | shared `/tmp` | 20 | **8** | **40%** |
| Private, reused | one private dir, reused | 12 | 1 (run **02**) | 8% |
| Fresh per run | empty dir per run | 12 | **0** | **0%** |

40% reproduces the banked ~1-in-3. Under that rate, 12 consecutive greens has probability
`0.6^12 ≈ 0.2%`.

The middle arm is the most informative: the only failure was **run 02**, the first run into
a directory populated by run 01, colliding with my own leftovers
(`fatal: 'run-wt-53' is already used by worktree at '…/privtmp/wt-root-55/run-54/git'`).
**Concurrency is not required** — a single sequential run collides with the residue of
previous runs. Concurrency only widens the window.

---

## 2. The load-bearing question: what fires `{:runtime_reconnected, _}` in the isolated run?

**Nothing.** The only producer in the repo is `runtime_channel.ex:97`, inside `join/3`:

```
$ grep -rn "runtime_reconnected" apps/ | sed 's/:.*//' | sort | uniq -c
      1 .../orchestration/task_router.ex          # a comment, line 398
      6 .../orchestration/task_router_watcher.ex
      1 .../platform_web/channels/runtime_channel.ex   # line 97 — the only broadcast
      1 .../notes/2026-07-06-datacase-cascade-rootcause.md
      6 .../test/platform/orchestration/task_router_watcher_boundary_test.exs
```

No file under `test/platform/execution/` joins a runtime channel; the single `subscribe`
there is `run_server_test.exs:213` on the unrelated `"execution:runs:#{task_id}"` topic. All
four files are `use ExUnit.Case, async: false` with zero `Repo.` calls.

So the reconnect callback is **never invoked** during the isolated run, and the isolated
failure was never evidence for the reconnect hypothesis.

---

## 3. Bug 2 — the full-suite failure, reproduced

Four full-suite runs on this tree:

| Run | Result |
|---|---|
| fullsuite01 | 21 doctests, 9791 tests, **0 failures**, 3 skipped |
| fullsuite02 | 21 doctests, 9791 tests, **0 failures**, 3 skipped |
| fullsuite03 | 21 doctests, 9791 tests, **0 failures**, 3 skipped |
| fullsuite04 | 21 doctests, 9791 tests, **1 failure**, 3 skipped |

1 failing run in 4. The test count (9791) matches the deployer's independent report exactly,
so we are on the same tree generation.

### 3.1 The visible failure is a victim, not the violator

`fullsuite04`'s single failure is in a module with no connection to this ticket:

```
  1) test closed captions (stage 2 — per-tile overlays) caption bar paints at z-40 (above the sticky mobile bottom-nav at z-30) (PlatformWeb.MeetingLiveTest)
     test/platform_web/live/meeting_live_test.exs:3598
     Assertion failed, no matching message after 100ms
     Showing 2 of 2 messages in the mailbox
     code: assert_receive {^ref, {:push_event, "join-meeting", %{token: _, url: _, room_name: _}}}
     mailbox:
       pattern: {^ref, {:push_event, "join-meeting", %{token: _, url: _, room_name: _}}}
       value:   {:plug_conn, :sent}
     stacktrace:
       test/platform_web/live/meeting_live_test.exs:3607: (test)
```

That is a test starved of a `push_event` because the connection underneath it was torn
down. **This is the "1 failure per run, passes on `--failed` in isolation" signature**: the
failing test is whichever one happens to be holding the poisoned connection when it dies.
Chasing the failing test name is chasing noise — it will differ every run.

### 3.2 The real population: 212 ownership violations in a single run

```
$ grep -c "owner #PID.* exited" fullsuite04.log
212

$ grep -o "Client #PID<[0-9.]*> ([^)]*)" fullsuite04.log | sed 's/#PID<[0-9.]*>//' | sort | uniq -c | sort -rn
    145 Client  (Platform.Orchestration.TaskRouterWatcher)
      7 Client  (Task.Supervised)
      2 Client  (:proc_lib)
     10 Client  ({Phoenix.LiveView, PlatformWeb.TasksLive, …})     # 10 distinct LiveViews
      2 Client  ({Phoenix.LiveView, PlatformWeb.MeetingLive, …})
```

**`TaskRouterWatcher` is 145 of 212 — 68% of all ownership violations in the suite.** These
are logged errors, not test failures; each one force-disconnects a pooled connection, and
occasionally that disconnect lands under a running test and produces the one visible
failure.

This also confirms and subsumes the independent deployer report of
`TasksLive.refresh_board/1`: `TasksLive` appears here too (10 instances). `TasksLive` has
**zero** `SandboxGuard` references (`grep -c` → 0) and its board handlers
(`tasks_live.ex:3043/3048/3051`) call `refresh_board/1` → `Tasks.list_all_tasks/1`
unguarded, subscribed via `Tasks.subscribe_board()` (line 94) to the *same* `tasks:board`
topic the watcher listens on. Real, but a minority contributor.

### 3.3 The verbatim raising frame

```
14:16:36.634 [error] Postgrex.Protocol (#PID<0.433.0> ("db_conn_6")) disconnected: ** (DBConnection.ConnectionError) owner #PID<0.2212.0> exited

Client #PID<0.504.0> (Platform.Orchestration.TaskRouterWatcher) is still using a connection from owner at location:

    :prim_inet.recv0/3
    (postgrex 0.22.0) lib/postgrex/protocol.ex:3272: Postgrex.Protocol.msg_recv/4
    (postgrex 0.22.0) lib/postgrex/protocol.ex:2967: Postgrex.Protocol.recv_transaction/4
    (postgrex 0.22.0) lib/postgrex/protocol.ex:2253: Postgrex.Protocol.rebind_execute/4
    (ecto_sql 3.13.5) lib/ecto/adapters/sql/sandbox.ex:412: Ecto.Adapters.SQL.Sandbox.Connection.proxy/3
    (db_connection 2.9.0) lib/db_connection/holder.ex:356: DBConnection.Holder.holder_apply/4
    (db_connection 2.9.0) lib/db_connection.ex:1539: DBConnection.run_execute/5
    (db_connection 2.9.0) lib/db_connection.ex:1587: DBConnection.run_with_retries/5
    (db_connection 2.9.0) lib/db_connection.ex:848: DBConnection.execute/4
    (ecto_sql 3.13.5) lib/ecto/adapters/postgres/connection.ex:143: Ecto.Adapters.Postgres.Connection.execute/4
    (ecto_sql 3.13.5) lib/ecto/adapters/sql.ex:1055: Ecto.Adapters.SQL.execute!/5
    (ecto_sql 3.13.5) lib/ecto/adapters/sql.ex:1011: Ecto.Adapters.SQL.execute/6
    (ecto 3.13.5) lib/ecto/repo/queryable.ex:241: Ecto.Repo.Queryable.execute/4
    (ecto 3.13.5) lib/ecto/repo/queryable.ex:19: Ecto.Repo.Queryable.all/3
    (ecto 3.13.5) lib/ecto/repo/queryable.ex:145: Ecto.Repo.Queryable.exists?/3
    (platform 0.1.0) lib/platform/orchestration/sandbox_guard.ex:161: Platform.Orchestration.SandboxGuard.guarded/3
    (platform 0.1.0) lib/platform/orchestration/task_router_watcher.ex:325: Platform.Orchestration.TaskRouterWatcher.handle_task_event/2
    (platform 0.1.0) lib/platform/orchestration/task_router_watcher.ex:177: Platform.Orchestration.TaskRouterWatcher.handle_info/2
    (stdlib 6.2.2) gen_server.erl:2345: :gen_server.try_handle_info/3
    (stdlib 6.2.2) gen_server.erl:2433: :gen_server.handle_msg/6
```

**The process that raised is `#PID<0.504.0>`, the singleton `TaskRouterWatcher`** — not the
ExUnit test process, not a `TaskRouter`, not a `Task.Supervisor` child.

### 3.4 Frame distribution — which callback

Each violation prints its stack twice ("still using" + "checked out by"), so halve these:

```
$ grep -o "TaskRouterWatcher\.[a-z_]*/[0-9]" fullsuite04.log | sort | uniq -c | sort -rn
    286 TaskRouterWatcher.handle_info/2
    242 TaskRouterWatcher.handle_task_event/2      <-- dominant
     16 TaskRouterWatcher.resolve_runtime_for_task/1
     16 TaskRouterWatcher.resolve_and_start/1
     16 TaskRouterWatcher.handle_runtime_reconnected/1
     16 TaskRouterWatcher.evaluate_task/1
     12 TaskRouterWatcher.redispatch_for_runtime/1

$ grep -o "task_router_watcher\.ex:[0-9]*" fullsuite04.log | sort | uniq -c | sort -rn
    258 task_router_watcher.ex:177    # handle_info({:task_created|:task_updated, task})
    227 task_router_watcher.ex:325    # handle_task_event/2 — task_row_visible?/1
     28 task_router_watcher.ex:182    # handle_info({:runtime_reconnected, _})
     16 task_router_watcher.ex:463
     16 task_router_watcher.ex:1094
     16 task_router_watcher.ex:1057
     15 task_router_watcher.ex:322    # handle_task_event/2 — connection_owned?/0
     14 task_router_watcher.ex:347    # handle_runtime_reconnected/1 — runtime_row_visible?/1
     12 task_router_watcher.ex:998
      2 task_router_watcher.ex:344    # handle_runtime_reconnected/1 — connection_owned?/0
```

So, precisely:

* **`handle_task_event/2` (the `:task_created` / `:task_updated` path) is the dominant
  violator** — ~113 of the 145, via lines 322 and 325.
* **`handle_runtime_reconnected/1` — the callback the ticket names — is a real but minor
  contributor**, ~8 of 145, via lines 344 and 347.

The ticket is therefore *not* wrong that this callback checks out a connection outside test
ownership. It is wrong about the magnitude, and it points at the smaller of two siblings
that share the identical defect.

---

## 4. §4 The four candidate mechanisms, judged separately per bug

Candidate labels are the plan's.

| # | Candidate | Bug 1 (isolated) | Bug 2 (full suite) |
|---|---|---|---|
| (a) | Repo call on an unguarded path reachable from `handle_runtime_reconnected/1` | **FALSIFIED** — zero `OwnershipError`/`DBConnection` text in all 20 runs; the execution tests make zero `Repo.` calls | **CONFIRMED, with a correction** — the path is real (lines 344/347) but is a *minority*; the dominant twin is `handle_task_event/2` |
| (b) | `send(pid, :dispatch)` waking a `TaskRouter` that queries unallowed | **FALSIFIED** — zero `TaskRouter` mentions in all 20 runs | **Not supported** — `redispatch_for_runtime/1` appears in only 12 frames, and the violations are in the watcher's own pid, not a router's |
| (c) | `Platform.Supervisor` max-restart cascade | **FALSIFIED** — zero `reached_max_restart_intensity` / `Supervisor … terminating` / `:noproc` / `exited in:` across 20 runs; and the tests go green on a `TMPDIR` change alone, which no supervisor theory explains | **FALSIFIED** — the cascade is at the *connection* level, not the supervisor level. No supervisor restart appears anywhere. |
| (d) | Global sandbox-mode mutation from `task_router_watcher_boundary_test.exs` | **FALSIFIED** — those files are not loaded by the isolated run | Not implicated; the violations have a sufficient mechanism without it |

On (c) specifically, since the brief flagged it as the leading hypothesis: **there is a
cascade, but it is not the supervisor's.** One straggler's query force-disconnects a pooled
connection (`Postgrex.Protocol … disconnected`), and an unrelated test holding that
connection fails. `Supervisor.count_children(Platform.Supervisor)` would **not** catch this,
so the stage-3 assertion built on it will not detect the real defect.

---

## 5. Why the existing guard does not prevent this — and makes it worse

`SandboxGuard` appears in **289** of the violation stacks, always at `sandbox_guard.ex:161`
— which is `fun.()` inside `guarded/3`. Every single violation runs *through* the guard.

The reason is structural. Both preconditions are themselves Repo operations:

```elixir
# sandbox_guard.ex:193-200
def connection_owned? do
  if sandbox_pool?() do
    guarded(fn -> Repo.checkout(fn -> true end) end, false, caller: __MODULE__)
  else
    true
  end
end
```

```elixir
# task_router_watcher.ex:364-371
defp runtime_row_visible?(runtime_id) do
  not SandboxGuard.sandbox_pool?() or
    SandboxGuard.guarded(
      fn -> Repo.exists?(from(r in AgentRuntime, where: r.runtime_id == ^runtime_id)) end,
      false, caller: __MODULE__)
end
```

`connection_owned?/0` **checks a connection out** (lines 322/344 in the stacks);
`task_row_visible?/1` / `runtime_row_visible?/1` **run a `SELECT EXISTS`** (lines 325/347 —
the single most frequent frame in the whole log). This is a time-of-check-to-time-of-use
race that cannot be closed by checking harder: the owner can exit *during* the probe, and
the probe is itself the query that gets caught.

`guarded/3` then `rescue`s the resulting exception, so no test crashes at that instant — but
the connection has **already been force-disconnected by Postgrex**. The guard converts a
loud failure into a silent connection kill, which then surfaces as an unrelated test failing
later. That is why 212 violations produce only 1 visible failure, and why the ticket's
suggested remedy — more guarding — would increase the violation count rather than reduce it.

The module's own docstring at lines 330-334 anticipates exactly this ("the connection can
still be torn down mid-flight if the test that allowed us onto it exits right here"). The
evidence says that caveat is the main event, not an edge case.

---

## 6. Side finding (confirmed, out of scope — do not fix here)

`config :platform, :start_attention_router, false` (`config/test.exs:48`) is honoured at
`application.ex:164`, so `Platform.Chat.AttentionRouter` **is not started in test**.
Therefore in `test/support/data_case.ex` its entry in `supervised_with_repo` never matches
(the `Sandbox.allow/3` is behind `if pid = Process.whereis(name)`), and the
`GenServer.call(pid, :__drain__, 2_000)` in `on_exit` never runs for it. Both are inert dead
test infrastructure rather than defects — the `Process.whereis/1` guards make them safe.
Worth deleting or re-enabling deliberately, in its own change.

---

## 7. What this means for stage 2

**The plan's three candidate designs need re-scoping against this evidence.**

1. **Bug 1 is not addressed by any of options A/B/C.** None of them would have changed any
   of the 32 isolated runs. Its hazard is in the test helpers —
   `local_runner_test.exs`'s `temp_dir/1` (~437), `unique_run_id/0` (451) and
   `setup_temp_git_repo/0` (478) must produce paths unique **across processes**, and must
   not silently re-enter an existing repo. ExUnit's built-in `@tag :tmp_dir` gives a
   per-test directory namespaced by module and test name and recreates it per run; that
   removes the class rather than one instance. The fix must also stop leaking directories,
   since the failure is driven by residue, not concurrency.

2. **For bug 2, Option A (start-gate the watcher in test) is the only one of the three that
   actually addresses the measured defect** — a watcher that does not run cannot produce
   145 violations. Option B (move Repo work off the reconnect path) fixes ~8 of 145 and
   leaves the dominant `handle_task_event/2` path untouched. Option C is inert for the
   reasons the plan already gives.

3. **The dominant frame belongs to the sibling task.** The plan declares
   `handle_task_event/2` (lines 320-337), `evaluate_task/1`, `resolve_and_start/1` and
   `resolve_runtime_for_task/1` as owned by task **`019fb977-0c50`** — and those are
   precisely the frames carrying ~113 of the 145 violations. This task, as scoped, owns the
   ~8-violation minority. **Fixing only what this task owns would leave 94% of the defect in
   place.** That is a scoping decision for a human, not for either executing agent; it is
   posted to the execution space rather than resolved here.

4. **The stage-3 test as specified will not detect this.** It asserts on
   `Supervisor.count_children(Platform.Supervisor)` and on the reconnect path. The measured
   defect is a connection-pool disconnect driven mainly by the *task-event* path. The
   assertion that would actually catch it is a count of
   `Postgrex.Protocol … disconnected: … owner … exited` log lines, or the
   `SandboxGuard.dropped_event/0` telemetry counter, across a suite run — not a supervisor
   child count.

Finally, per the stage constraints: the four `Platform.Execution.*` test files were **not**
modified, quarantined, moved, renamed, retried, or had their `async` flags changed, and no
production code was changed in this stage.

---

# Stage 2 — the production fix

Two independent fixes, one per bug. Kept legible as two.

## 8. Option chosen: **A, start-gate the watcher in test**

Stage 1's measurement decided this, not preference.

| Option | What it would have fixed | Verdict |
|---|---|---|
| **A — start-gate in test** | All 145 watcher violations, by **any** frame | **CHOSEN** |
| B — move Repo work off the reconnect hot path | ~8 of 145 (`handle_runtime_reconnected/1` only) | Rejected: leaves 94% in place |
| C — explicit `Sandbox.allow/3` from the owning test | 0 | Rejected: this is *already* what `data_case.ex` did, and it is the mechanism of the bug (§below), not a fix for it |

**Why B is not enough, in one line:** the dominant frame is `handle_task_event/2`
(~113 of 145), which this task does not own. B is frame-scoped; A is not. A watcher
that does not exist during a test cannot perturb it by any route — which is exactly
what matters when the dominant route belongs to someone else's ticket.

**Why C is actively wrong.** `data_case.ex` allow-listed the watcher into every
test's sandbox. That allowance binds the *global singleton* to *this* test's
connection. The watcher outlives the test; the next `tasks:board` broadcast reaches
a process still bound to a dead connection. Allow-listing a singleton into a
per-test sandbox is not a fix for cross-test leakage, it is the delivery mechanism
for it.

**And the constraint the stage set — removal, not suppression — is satisfied.** No
rescue clause was added, `SandboxGuard.guarded/3`'s catch was not widened, and
`Platform.Supervisor`'s `max_restarts` was not touched. The hazardous process simply
does not run.

### 8.1 Before / after, measured

Three full-suite runs on the fixed tree, `PLATFORM_TEST_DATABASE=platform_test_019fb978`:

| | Banked (stage 1) | run 01 | run 02 | run 03 |
|---|---|---|---|---|
| Tests | 9791 | 9791 | 9791 | 9791 |
| Failures | 1 | 1 † | **0** | **0** |
| `owner … exited` violations | **212** | **72** | **78** | **95** |
| …of which `TaskRouterWatcher` | **145** | **0** | **0** | **0** |

† run 01's single failure was `SupervisedTaskRepoAuditTest` — see §8.3. It is not a
flake and not a victim; it is a guard rail that fired correctly.

**145 → 0 is the headline.** Total violations fall 212 → 72–95; the residue is
`Task.Supervised`, `DeadLetterReplay` and LiveView processes, all pre-existing and
all out of this task's scope (they are stage 5's sweep).

**Census caveat, per the sibling task.** `019fb977` stage 2 added a test that
deliberately manufactures exactly **one** `DBConnection.OwnershipError` per full
run — a raw `spawn/1` exercising the `:sandbox_unowned` refusal path honestly. It is
a checkout refusal rescued in-process: no Postgrex disconnect, no victim. It does
not appear in the numbers above (that branch is not merged here), but any future
grep-based census on a tree containing it should compare **count − 1**. A census that
silently drifts by one is how a measurement loses its reader.

### 8.2 Every test that moved, and why

The stage said to find these by running the full suite rather than assuming there
were none. There were four, and one of them was a surprise.

| File | Change | Why |
|---|---|---|
| `orchestration/task_router_watcher_test.exs` | `start_supervised!(TaskRouterWatcher)` in `setup`, after the shared-mode switch | Uses `Process.whereis/1` + `sync/0` throughout |
| `orchestration/task_router_watcher_boundary_test.exs` | `Process.whereis` → `start_supervised!`, before the mode switch | The mode switch drops allowances, which is what keeps the existing `assert Sandbox.allow(...) == :ok` meaningful and the `:unowned_watcher` branch genuinely unowned |
| `orchestration/task_router_watcher_sandbox_isolation_test.exs` | same | same |
| `orchestration/task_router_test.exs` | `start_supervised!` in ONE test | `:2352` calls `TaskRouterWatcher.sync/0`, a `GenServer.call` that would exit `:noproc`. Worse than a crash if left: the assertion there is that a router is **absent**, and "no watcher exists" satisfies that vacuously |

**Two of the five files the stage named did not need changing**, and this is a
finding rather than a shortcut: `task_router_watcher_stall_sweep_test.exs` and
`task_router_watcher_gate_expiry_sweep_test.exs` call only `sweep_in_review_stalls/0`,
`sweep_expired_architecture_gates/0`, `should_run?/1` and `router_running?/1` — all
plain module functions evaluated in the test process. `sync/0` is the **only** entry
point on this module that requires the process to exist. Both files pass unchanged.

**One coverage loss, named:**
`regression/task_supervisor_ownership_leak_test.exs` — "Belt (C)" asserted the
watcher was still alive after the cascade, behind an `if watcher_pid do` guard.
`whereis/1` is now always `nil`, so the assertion could never execute again. It was
**deleted, not left in place**: an assertion that cannot run still reads as coverage,
which is the exact vacuity pattern this codebase is fighting. It was not re-armed
with a per-case watcher because that module is `async: true` on purpose (per-owner
sandbox is what makes the leak fire) and adding a Repo-touching singleton to it would
reintroduce the hazard. The belt's own comment already conceded it was "not directly
proven by this isolated test".

**One inert-but-harmless site, left alone:**
`mix/tasks/platform/cleanup_ghost_tasks_test.exs` guards its `Sandbox.allow/3` with
`if pid = Process.whereis(...)`, so it degrades to a no-op. Its assertions use
`router_running?/1` (a bare `Registry.lookup`) and it starts its own routers, so it
passes unchanged. Same dead-test-infrastructure shape as the `AttentionRouter`
finding in §6.

### 8.3 The audit test caught this before a human did

`Platform.Regression.SupervisedTaskRepoAuditTest` failed on the first full-suite run
with the new gate:

```
  1) test Platform.Application maybe_add_* start flags every :start_* flag application.ex reads is false in test env (Platform.Regression.SupervisedTaskRepoAuditTest)
     test/platform/regression/supervised_task_repo_audit_test.exs:238
     Platform.Application added new maybe_add_* gates without updating
     the audit test. Add the new flag(s) to
     @expected_disabled_flags in
     test/platform/regression/supervised_task_repo_audit_test.exs AND
     set them to `false` in config/test.exs:

       - start_task_router_watcher
```

Worth recording because it is the system working: that test exists precisely to stop
a `maybe_add_*` gate defaulting to `true` and booting a real singleton under the
DataCase sandbox — the 2026-07-03 cascade shape. The flag is now registered in
`@expected_disabled_flags` with its rationale.

## 9. Bug 1 — the `/tmp` collision, fixed separately

Scope: `local_runner_test.exs` temp-path construction and teardown only. Nothing else
in that file was refactored.

`temp_dir/1`, `unique_run_id/0` and the worktree branch name now draw from
`Base.encode32(:crypto.strong_rand_bytes(10))` instead of `System.unique_integer/1`,
and every path hangs off ONE root created in `setup_all` and `File.rm_rf`'d in its
`on_exit`. Randomness rather than a counter is the whole point: the value has to be
unique across **OS processes**, and no per-VM counter can be. The root plus its
teardown is the other half — §1.4's middle arm proved residue alone is sufficient to
fail, with no concurrency required.

**Result: 12/12 green on the shared `/tmp`** — the same arm that measured 8/20
failing (40%). Under that rate, 12 consecutive greens has probability
`0.6^12 ≈ 0.22%`. Test count unchanged at 65. The `error: remote origin already
exists.` line — the collision announcing itself in *every* previous run, green ones
included — is gone from all 12.

### 9.1 The identical defect exists in two sibling files — reported, NOT changed

```
docker_runner_test.exs:621: Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
proof_run_test.exs:23:     Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
```

Byte-for-byte the same construction and therefore the same defect: machine-global
namespace × per-VM counter, no cleanup. Neither was observed failing in the 32
measured runs, so this is a latent instance rather than a reproduced one. Left
unchanged because the stage-2 scope grant was explicitly limited to
`local_runner_test.exs` and required these be *reported* before being touched. They
should be fixed with the identical shape in a follow-up.

`run_server_test.exs` is **clean** on this axis: its `System.unique_integer/1` uses
build run/task **ids**, not filesystem paths, so a repeat across runs is harmless.

## 10. Constraint this places on sibling task `019fb977` — not silent

Start-gating the watcher **forecloses one of `019fb977`'s candidate designs as
written**. Their "TaskRouterWatcher tears down and respawns the router when the phase
assignee changes" behaviour is no longer observable through the global singleton in
test, because there is no global singleton in test. Their tests must
`start_supervised!(TaskRouterWatcher)` and `Sandbox.allow/3` it, exactly as the three
watcher files here now do.

Their stage 3 is adding an assertion to `task_router_watcher_test.exs` — the file
this stage converted — so that is a live merge point, not a hypothetical.

This is a sequencing decision for a human, not for either executing agent. It is
recorded here, in the stage-2 commit message, and posted to the execution space.

## 11. Carried to stage 5: `LeaseManager`'s ETS lifetime is a THIRD corruption route

Surfaced by `019fb977` stage 3, recorded here because stage 5's sweep is where it
belongs and because it changes how a census should be read.

`Platform.Orchestration.LeaseManager` creates `:orchestration_lease_manager` as a
`:named_table, :public` ETS table inside its own `init/1` (its comment at
`lease_manager.ex:144` says so), so the table **dies with its owner**. Any restart of
that global singleton wipes every task's lease row at once, and a concurrent test
sees `LeaseManager.get(task_id)` return `nil` for a lease it just created.
`019fb977` hit exactly that at `task_router_stage_isolation_test.exs:307`, seed 0,
with a second run on the identical tree at the identical seed coming back clean.

This is a **different mechanism from the one this task fixes**: no Repo call, no
sandbox ownership, no Postgrex disconnect. It is a global singleton mutating
non-transactional state whose lifetime is bound to a restartable process — the third
route by which a supervised singleton corrupts shared test state, alongside the
ownership violations in §3 and the `/tmp` residue in §1.

**Consequence for any census.** A `nil`-lease failure is NOT an ownership violation
and counting it as one overstates the defect being fixed. The three stage-2 runs
above are clean of it: zero `LeaseManager.get` hits in all three logs, and the only
failure across them was the audit test in §8.3.

Stage 5's table already scopes `:orchestration_lease_manager` under "mutates global
non-transactional state?" — this is the concrete mechanism behind that column. It
gets its own row and its own verdict there. Not fixed in stage 2: different module,
different lifetime problem.

# Stage 3 — the deterministic reconnect regression test

New file:
`apps/platform/test/platform/regression/task_router_watcher_reconnect_ownership_test.exs`
(5 tests). Structure and rules mirror
`test/platform/orchestration/task_router_watcher_sandbox_isolation_test.exs`.

## 12. Two premises in the stage description were dead on arrival

Recorded because the stage text still carries them and the next reader will
otherwise re-derive the correction.

**12.1 The supervisor cascade is falsified, so the snapshot is a belt.** The stage
asked for a `Supervisor.count_children(Platform.Supervisor)` +
`Platform.Execution.RunSupervisor` pid snapshot, described as "the assertion that
catches the max-restart cascade from stage 1 candidate (c)". §4 of this note
already falsified candidate (c): **zero max-restart terminations and zero `:noproc`
events across 20 runs**, and the isolated flake turned out to be the `/tmp`
collision in §1.

Disposition: **the snapshot is KEPT, and demoted in writing.** It is two function
calls per hostile-reconnect test, it would still catch a future regression that
took `Platform.Supervisor` down, and it costs nothing. It is NOT presented as the
thing that catches the defect, and no assertion in the file depends on it — the
`assert_watcher_survived/3` helper that carries it says so in a comment, as does
the moduledoc under "On the supervision snapshot". A belt described as a belt.

**12.2 `TaskRouterWatcher` no longer runs in test.** After stage 2's Option A,
`Process.whereis(TaskRouterWatcher)` is `nil` by default, so the file
`start_supervised!`s its own — ordered *before* the sandbox mode switch, exactly
as the three orchestration files now do, because the switch drops every allowance
derived from the shared connection. That ordering is what keeps
`assert Sandbox.allow(Repo, self(), watcher) == :ok` meaningful (rather than
`{:already, :allowed}`) and what leaves the watcher genuinely unowned on the
`:unowned_watcher` branch.

## 13. Pre-fix failure — verbatim, and an honest reading of its shape

### 13.1 How it was produced

The stage-2 production + harness change was reverted, leaving the stage-3 test in
place. This is control 1 of stage 4 and the shape the task-level `e2e_behavior`
validation prescribes (`git revert` the production commit only, keep the tests):

```
$ git checkout 213ecc29 -- apps/platform/config/test.exs \
                           apps/platform/lib/platform/application.ex \
                           apps/platform/test/support/data_case.ex
$ cd apps/platform
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 \
    mix test test/platform/regression/task_router_watcher_reconnect_ownership_test.exs
```

`213ecc29` is the stage-2 parent commit (stage 1, notes only — no production
change). The three reverted files are the entirety of stage 2's non-test surface.

### 13.2 Verbatim output

```
Running ExUnit with seed: 275079, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]



  1) test arm 1 — direct mailbox drive, intended effect (half 2) the same reconnect does NOT redispatch when an active lease already exists (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:256
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  2) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:225
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  3) test observability control a reconnect for a runtime_id with no row on any connection is observably refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:362
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2

Finished in 0.2 seconds (0.00s async, 0.2s sync)
5 tests, 5 failures
```

(Failures 4 and 5 are the two remaining tests, identical message, elided only in
this excerpt for length; the full 5-of-5 block is reproduced above for 3 of them
and every one carries the same `__ex_unit_setup_1/1` frame at line 173.)

### 13.3 THE SHAPE DIFFERS FROM THE OWNERSHIP VIOLATION. Read this before citing it.

The acceptance bar — "if the file passes against pre-fix code the stage is not
done" — is met: **5 of 5 fail, deterministically, every run.** But the failure is
NOT a `DBConnection.OwnershipError` and it would be dishonest to file it as one.

* **What actually fails.** The `refute Process.whereis(TaskRouterWatcher)`
  precondition in `setup`, at line 173. On the pre-fix tree the global singleton
  holds the registered name, so `start_supervised!(TaskRouterWatcher)` cannot
  construct the fixture. Before that assertion was added the same run failed with
  `** (RuntimeError) failed to start child with the spec
  Platform.Orchestration.TaskRouterWatcher. Reason: bad child specification, got:
  {:already_started, #PID<0.3392.0>}` — same cause, opaque phrasing. The assertion
  was added so the failure names the finding instead of the symptom.

* **Why it fails there and not in a callback.** Every assertion in this file is
  about `handle_runtime_reconnected/1`'s *guards*, and §3/§5 of this note
  established that those guards were ALREADY on `origin/main` before this task
  started. Stage 2 did not add them; it removed the process that was firing them
  against foreign connections. So there is no pre-fix state in which the guards
  are absent — which means no pre-fix state in which this file's assertions go red
  for an ownership reason. **The file cannot reproduce the ownership violation
  through its own assertions, and no rewrite of it could, because the defect
  stage 2 fixed was architectural (a singleton outliving its connection), not a
  missing branch.**

* **What that failure IS worth.** It is the precise statement that the file's
  fixture is unconstructible pre-fix: a per-test-owned watcher only became
  possible because stage 2 removed the singleton. That is a real property of the
  fix, deterministically demonstrated, and it is the strongest thing this file can
  say about the parent commit.

* **Where the ownership-shape pre-fix evidence actually lives.** §3.3 of this
  note, banked in stage 1 at the same parent commit: the verbatim
  `Postgrex.Protocol ... disconnected: ** (DBConnection.ConnectionError) owner
  #PID<0.2212.0> exited` block with
  `Platform.Orchestration.TaskRouterWatcher.handle_info/2` in the stack, 145 per
  full-suite run. Cite §3.3 for the violation; cite §13.2 for the fixture
  incompatibility. They are two different measurements and conflating them would
  overstate what this file proves.

* **What DOES make the assertions discriminating** is mutation of the guards
  themselves — stage 4's job. Two of those controls were run early here as a
  sanity check on the file before committing it; see §14. They are re-run and
  transcribed in full in stage 4, not counted as done by this section.

## 14. Two mutation controls run early, as a check on the file itself

Not a substitute for stage 4 — those eight are transcribed there with full
command and output. These two were run because shipping a file whose central
claim ("the mirror distinguishes dispatched from not-dispatched") was unverified
would be exactly the vacuity defect this task exists to close.

**14.1 The mirror distinguishes.** `active_lease_present?/2`
(`task_router_watcher.ex:1041`) neutered to return `false` unconditionally:

```
  1) test arm 1 — direct mailbox drive, intended effect (half 2) the same reconnect does NOT redispatch when an active lease already exists (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:244
     Unexpectedly received message {:dispatched, "019fb9cc-d032-7fcf-a142-f169ca6828fe"} (which matched {:dispatched, ^task_id})
     code: refute_received {:dispatched, ^task_id}
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:267: (test)

....
Finished in 0.4 seconds (0.00s async, 0.4s sync)
5 tests, 1 failure
```

Exactly one test moved. The `refute_received` is load-bearing, not decorative:
the harness genuinely observes the difference between a dispatch that happened
and one that was suppressed, and the ONLY input that changed between the positive
and the mirror is one `ExecutionLease` row.

**14.2 The vacuity control — half 2 fails, half 1 survives.**
`redispatch_for_runtime/1` replaced with `defp redispatch_for_runtime(_rid), do:
:ok`:

```
  1) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:213
     the watcher did not redispatch a router for a task assigned to the reconnected runtime — half 1 of this file would still pass, which is exactly why half 2 exists
     code: assert_receive {:dispatched, ^task_id},
```

Half 1's three drop tests stayed green throughout. That is the two-halves-are-
independent property stated as a measurement rather than as an intention: a
watcher that silently stopped redispatching would be caught here and nowhere else
in the suite.

Both mutations were reverted; `git status` clean of them before commit.

## 15. Post-fix result

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 \
    mix test test/platform/regression/task_router_watcher_reconnect_ownership_test.exs
5 tests, 0 failures
```

**10 consecutive runs across 10 distinct seeds (`--seed 1237 … 12370`): 10/10
green, 5 tests each.** No retries, no `Process.sleep`, no polling, no `async`
change, no test moved or renamed. The only bounded `assert_receive` in an
ordering position is the positive dispatch assertion, and its bound is a
failure-reporting budget sitting behind two `GenServer.call` barriers
(`TaskRouterWatcher.sync/0` then `StubRouter.sync/1`); every `refute_received` in
the file carries no timeout at all, which is only sound because those barriers
returned first.

# Stage 4 — eight mutation controls

Every block below is the exact command and the exact ExUnit output, unedited
except for the compiler-warning preamble (`origin/main` fails
`--warnings-as-errors` under ticket `019fb8c9`; not part of this gate). All
runs are from the task worktree at `446283d4` with
`PLATFORM_TEST_DATABASE=platform_test_019fb978`. Every mutation was reverted
and `git status` verified clean between controls; `git diff --stat 446283d4`
is empty at the end of the stage.

Shorthand for the target file, used below:

```
TESTFILE=test/platform/regression/task_router_watcher_reconnect_ownership_test.exs
```

Baseline immediately before control 1, same command, `5 tests, 0 failures`
(seed 866028).

## 16. Corrections carried into this stage

Three premises in the stage-4 description were already falsified by stages 1–3.
Recorded here so the controls below are read against what is true rather than
against what was planned.

**16.1 Control 1's failure is not, and cannot be, an ownership failure.**
§13.3 established it: `handle_runtime_reconnected/1`'s guards were already on
`origin/main` before this task began. Stage 2 removed the *process* that was
firing them against foreign connections; it did not add the guards. So there is
no pre-fix tree in which this file's assertions go red for an ownership reason,
and no rewrite of the file could produce one. Control 1 reproducing §13.2's
fixture-unconstructible failure **is a pass**. The ownership-shape pre-fix
evidence is a separate measurement banked at §3.3 (`owner #PID<…> exited`, with
`TaskRouterWatcher.handle_info/2` in the stack, 145 per full-suite run). The two
are not interchangeable and are not merged anywhere in this note.

**16.2 Controls 2 and 3 delete guards that predate this task.** They still
detonate — the stage-3 file asserts on specific drop *reasons*, not on the
existence of a guard — but what they measure is the discriminating power of
those assertions, not the presence of a stage-2 fix.

**16.3 The cascade premise is dead and is not a mechanism here.** §4 measured
zero max-restart terminations and zero `:noproc` across 20 runs. The
`Supervisor.count_children/1` snapshot in the stage-3 file is a documented belt
(§12.1); no control below is premised on it and no control below moved it.

## 17. Control 1 — revert the stage-2 production fix entirely

```
$ git checkout 213ecc29 -- apps/platform/config/test.exs \
                           apps/platform/lib/platform/application.ex \
                           apps/platform/test/support/data_case.ex
$ cd apps/platform
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 741706, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]



  1) test arm 1 — direct mailbox drive, intended effect (half 2) the same reconnect does NOT redispatch when an active lease already exists (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:256
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  2) test observability control a reconnect for a runtime_id with no row on any connection is observably refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:362
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  3) test arm 2 — real broadcast_board fan-out from a foreign connection (half 1) a reconnect for a runtime that exists only on another connection is refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:294
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  4) test arm 2 — real broadcast_board fan-out from a foreign connection (half 1) the same reconnect is refused for connection ownership when the watcher owns nothing (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:331
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2



  5) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:225
     a global TaskRouterWatcher is running. It outlives every individual test, so it cannot be given a per-test sandbox connection and this file cannot own one — see :start_task_router_watcher in config/test.exs (task 019fb978 stage 2)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:173: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit_setup_1/1
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:1: Platform.Regression.TaskRouterWatcherReconnectOwnershipTest.__ex_unit__/2


Finished in 0.1 seconds (0.00s async, 0.1s sync)
5 tests, 5 failures
```

**Verdict: DETONATED AS PREDICTED.** 5 of 5, matching §13.2's banked block
message-for-message and frame-for-frame — same text, same
`__ex_unit_setup_1/1` at line 173, on a different seed (741706 vs 275079).
§13.2 elided two of the five for length; all five are reproduced here, and the
elided two carry the identical message, which is now measured rather than
asserted.

Read against §16.1: this is the fixture-incompatibility failure, not an
ownership failure, and that is the correct and only possible outcome. It was
NOT "fixed" into an ownership error, because doing so would require a defect
that does not exist.

## 18. Control 2 — delete precondition A (`connection_owned?`)

Mutation: the `not SandboxGuard.connection_owned?() -> drop(:connection_unowned, …)`
clause removed from `handle_runtime_reconnected/1`, leaving precondition B and
the guarded call.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 609300, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

.

  1) test arm 2 — real broadcast_board fan-out from a foreign connection (half 1) the same reconnect is refused for connection ownership when the watcher owns nothing (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:331
     The watcher never recorded a :connection_unowned drop for runtime_id="reconnect-foreign-57736" within 5000ms — it handled the reconnect instead of refusing it.

     State right now:
       AgentRuntime row visible here?  false
       Registry contents:              []

     code: await_drop!(runtime_id, :connection_unowned)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:346: (test)

...
Finished in 5.3 seconds (0.00s async, 5.3s sync)
5 tests, 1 failure
```

**Verdict: DETONATED AS PREDICTED.** Exactly one named assertion moved — the
`:unowned_watcher` test's `await_drop!(runtime_id, :connection_unowned)`.

The second thing this measures, which the stage did not ask for and which is
the more useful half: **the two refusal paths do not collapse onto one atom.**
With A deleted, B fires and the drop arrives tagged `:foreign_connection`; the
test does not accept it, because it selective-receives on
`%{runtime_id: ^runtime_id, reason: :connection_unowned}` specifically. "Two
distinct refusal paths returning the same atom" is one of the named defect
shapes this week; it is measured absent here rather than argued absent.

## 19. Control 3 — delete precondition B (`runtime_row_visible?`)

Mutation: the `not runtime_row_visible?(runtime_id) -> drop(:foreign_connection, …)`
clause removed, leaving precondition A and the guarded call.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 368835, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

.

  1) test arm 2 — real broadcast_board fan-out from a foreign connection (half 1) a reconnect for a runtime that exists only on another connection is refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:294
     The watcher never recorded a :foreign_connection drop for runtime_id="reconnect-foreign-355" within 5000ms — it handled the reconnect instead of refusing it.

     State right now:
       AgentRuntime row visible here?  false
       Registry contents:              []

     code: await_drop!(runtime_id, :foreign_connection)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:323: (test)

.

  2) test observability control a reconnect for a runtime_id with no row on any connection is observably refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:362
     The watcher never recorded a :foreign_connection drop for runtime_id="reconnect-nowhere-3906" within 5000ms — it handled the reconnect instead of refusing it.

     State right now:
       AgentRuntime row visible here?  false
       Registry contents:              []

     code: await_drop!(runtime_id, :foreign_connection)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:378: (test)

.
Finished in 10.3 seconds (0.00s async, 10.3s sync)
5 tests, 2 failures
```

**Verdict: DETONATED AS PREDICTED.** Both named `:foreign_connection`
assertions moved — arm 2's foreign-row case and the observability control —
and nothing else did. Controls 2 and 3 together show the two preconditions are
independently deletable-and-caught: neither one masks the other, which is the
"two mechanisms masking each other so either was deletable" defect measured
absent.

## 20. Control 4 — `SandboxGuard.connection_owned?/0` returns `false` unconditionally

Mutation: the whole body replaced with `false` (the drop-everything
implementation). `sandbox_pool?/0` untouched.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 381582, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]



  1) test observability control a reconnect for a runtime_id with no row on any connection is observably refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:362
     The watcher never recorded a :foreign_connection drop for runtime_id="reconnect-nowhere-1604" within 5000ms — it handled the reconnect instead of refusing it.

     State right now:
       AgentRuntime row visible here?  false
       Registry contents:              []

     code: await_drop!(runtime_id, :foreign_connection)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:378: (test)

..

  2) test arm 2 — real broadcast_board fan-out from a foreign connection (half 1) a reconnect for a runtime that exists only on another connection is refused (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:294
     The watcher never recorded a :foreign_connection drop for runtime_id="reconnect-foreign-677" within 5000ms — it handled the reconnect instead of refusing it.

     State right now:
       AgentRuntime row visible here?  false
       Registry contents:              []

     code: await_drop!(runtime_id, :foreign_connection)
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:323: (test)



  3) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:225
     the watcher did not redispatch a router for a task assigned to the reconnected runtime — half 1 of this file would still pass, which is exactly why half 2 exists
     code: assert_receive {:dispatched, ^task_id},
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:242: (test)


Finished in 15.4 seconds (0.00s async, 15.4s sync)
5 tests, 3 failures
```

**Verdict: DETONATED AS PREDICTED, including the condition the stage singled
out.** Failure 3 is half 2's dispatch-delivered assertion. The stage's stated
bar — *"half 2's dispatch-delivered assertion MUST fail; if only half 1 reacts,
half 2 is not actually observing the watcher's effect"* — is met: half 2 did
react. Failures 1 and 2 are the two `:foreign_connection` sites, which now
receive `:connection_unowned` instead and correctly refuse to accept it (the
same atom-collapse check as §18, from the opposite direction).

## 21. Control 5 — THE VACUITY CONTROL: `redispatch_for_runtime/1` does nothing

Mutation: the entire body, its `rescue DBConnection.OwnershipError` and its
`catch :exit, _` replaced with
`defp redispatch_for_runtime(_runtime_id), do: :ok`. Both preconditions left
intact.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 440605, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

...

  1) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:225
     the watcher did not redispatch a router for a task assigned to the reconnected runtime — half 1 of this file would still pass, which is exactly why half 2 exists
     code: assert_receive {:dispatched, ^task_id},
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:242: (test)

.
Finished in 5.4 seconds (0.00s async, 5.4s sync)
5 tests, 1 failure
```

**Verdict: DETONATED AS PREDICTED, exactly.** One failure, and it is half 2's
positive dispatch assertion. Half 1's three drop tests stayed green — the three
dots and the trailing dot around the failure are them. This is the property the
whole task rests on, stated as a measurement: **a watcher that silently stopped
redispatching is caught here, by this assertion, and nowhere else in the
suite.** A green run of this file therefore distinguishes a working reconnect
from a reconnect that did nothing.

This control was run once during stage 3 as a pre-commit sanity check (§14.2,
partial output). Stage 3 explicitly did not count it as done; it is re-run here
on a fresh seed with the full output block, and the result is the same.

## 22. Control 6 — remove only `send(pid, :dispatch)`, keep every Repo call

Mutation: `task_router_watcher.ex:1013` — the single `send(pid, :dispatch)`
inside `redispatch_for_runtime/1`'s `true ->` branch — replaced with `_ = pid`.
`list_should_run_tasks/0`, `resolve_runtime_for_task/1`, `router_running?/1`,
`active_lease_present?/2`, the `Registry.lookup/2` and the `Logger.info` all
still run, and the function still counts and reports the same number of
redispatches.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 698786, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]



  1) test arm 1 — direct mailbox drive, intended effect (half 2) a reconnect for a visible runtime redispatches that runtime's router (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:225
     the watcher did not redispatch a router for a task assigned to the reconnected runtime — half 1 of this file would still pass, which is exactly why half 2 exists
     code: assert_receive {:dispatched, ^task_id},
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:242: (test)

....
Finished in 5.4 seconds (0.00s async, 5.4s sync)
5 tests, 1 failure
```

**Verdict: DETONATED AS PREDICTED.** Same single failure as control 5, reached
by deleting one line instead of forty-five. Read against control 5 this is the
sharper of the two: control 5 removes the Repo work *and* the send, so its
failure is consistent with half 2 merely observing "some Repo work happened".
Control 6 removes **only** the send and half 2 still fails, which pins the
assertion to the actual observable output of the callback. Half 1 green in both.
The two halves are independent and neither masks the other — measured twice, by
two different deletions.

## 23. Control 7 — delete the `TaskRouterWatcher.sync/0` barrier, run 10 times

This is the control on the determinism claim itself. Mutation: the five
in-test `assert TaskRouterWatcher.sync() == :ok` ordering barriers (lines 238,
273, 325, 348, 380) replaced with a comment. The sixth `sync/0` — the
`{:task_created, _}` drain inside `seed_dispatchable_task!/0` at line 454 — was
deliberately LEFT, because it drains an unrelated broadcast rather than
ordering an assertion, and removing it would confound two effects in one run.
`StubRouter.sync/1` also left in place.

```
$ for i in $(seq 1 10); do
    PLATFORM_TEST_DATABASE=platform_test_019fb978 \
      mix test $TESTFILE --seed $((1000 + i * 137))
  done
```

```
run1(seed 1137): 5 tests, 0 failures
run2(seed 1274): 5 tests, 0 failures
run3(seed 1411): 5 tests, 0 failures
run4(seed 1548): 5 tests, 0 failures
run5(seed 1685): 5 tests, 0 failures
run6(seed 1822): 5 tests, 0 failures
run7(seed 1959): 5 tests, 0 failures
run8(seed 2096): 5 tests, 0 failures
run9(seed 2233): 5 tests, 0 failures
run10(seed 2370): 5 tests, 0 failures
```

**Verdict: DID NOT DETONATE — 10/10 green without the barrier. Reported, not
dropped.**

Taken at face value this says the barrier buys nothing. It does not say that,
and the reason is worth writing down because the same trap will recur: **on an
unmutated tree there is no signal for the assertions to race against.** Every
positive assertion in the file is either a blocking selective receive
(`await_drop!/2`) or a bounded `assert_receive`, both of which wait on their own
account. The only assertion whose soundness actually depends on the barrier is
the mirror's un-timed `refute_received {:dispatched, ^task_id}` — and on an
unmutated tree nothing is ever dispatched there, so it passes whether it is
ordered or not. A green 10/10 here is consistent with the barrier being
load-bearing AND with it being decorative. The control as specified cannot
distinguish them.

### 23.1 The paired form that can distinguish them

So the control was paired with a mutation that gives the mirror something to
catch: `active_lease_present?/2` neutered to `false` (the §14.1 mutation, which
with barriers in place produces exactly one failure). Same ten seeds run twice,
once with the barriers deleted and once with them restored — the only variable
is the barrier.

**7b — barriers DELETED, `active_lease_present?/2 -> false`:**

```
$ for i in $(seq 1 10); do
    PLATFORM_TEST_DATABASE=platform_test_019fb978 \
      mix test $TESTFILE --seed $((3000 + i * 211))
  done

run1(seed 3211): 5 tests, 0 failures
run2(seed 3422): 5 tests, 0 failures
run3(seed 3633): 5 tests, 0 failures
run4(seed 3844): 5 tests, 0 failures
run5(seed 4055): 5 tests, 0 failures
run6(seed 4266): 5 tests, 0 failures
run7(seed 4477): 5 tests, 0 failures
run8(seed 4688): 5 tests, 0 failures
run9(seed 4899): 5 tests, 0 failures
run10(seed 5110): 5 tests, 0 failures
```

**7c — barriers RESTORED, same mutation, same first five seeds:**

```
run1(seed 3211): 5 tests, 1 failure
run2(seed 3422): 5 tests, 1 failure
run3(seed 3633): 5 tests, 1 failure
run4(seed 3844): 5 tests, 1 failure
run5(seed 4055): 5 tests, 1 failure
```

Run 1 of 7c in full:

```
Running ExUnit with seed: 3211, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]



  1) test arm 1 — direct mailbox drive, intended effect (half 2) the same reconnect does NOT redispatch when an active lease already exists (Platform.Regression.TaskRouterWatcherReconnectOwnershipTest)
     test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:256
     Unexpectedly received message {:dispatched, "019fb9e0-5153-77d3-a3f6-8b8f2542d80e"} (which matched {:dispatched, ^task_id})
     code: refute_received {:dispatched, ^task_id}
     stacktrace:
       test/platform/regression/task_router_watcher_reconnect_ownership_test.exs:279: (test)

....
Finished in 0.4 seconds (0.00s async, 0.4s sync)
5 tests, 1 failure
```

**Finding: the barrier IS load-bearing, and it is load-bearing for exactly one
assertion.** On identical seeds, with the identical production mutation, the
mirror catches the stray dispatch 5/5 with the barrier and 0/10 without it. The
dispatch still fires without the barrier — controls 5 and 6 prove the `send`
happens — the `refute_received` simply runs before it arrives. Without
`TaskRouterWatcher.sync/0` the mirror is a **vacuous refutation**: it would pass
against a watcher that had lost its lease guard entirely.

`StubRouter.sync/1` does not substitute for it, and 7b is the measurement that
says so: it was present throughout. It is answered after the messages already
in the *stub's* mailbox, and if the watcher has not yet handled the reconnect
then the stub's mailbox is empty and the call returns immediately. It chains
onto `TaskRouterWatcher.sync/0`; it does not replace it.

This is the answer the stage asked for, and it is the opposite of the one the
naive form of the control returned. **Reporting the 10/10 green alone would have
been true and misleading.** No change is made to the file: the barrier is
already there and is already correct. What changes is that its necessity is now
measured (5/5 vs 0/10 on matched seeds) rather than argued from the semantics of
`GenServer.call`.

## 24. Control 8 — the observability control: arm 2 pointed at a runtime that exists nowhere

Mutation (test-side, as specified): arm 2's first test keeps its foreign owner
and still creates a foreign runtime, but the `runtime_id` it broadcasts is a
synthetic one with **no `AgentRuntime` row on any connection**. The two
preconditions are replaced by the assertion that the row is absent on both
connections:

```elixir
_ = create_foreign_runtime!(owner)
runtime_id = "reconnect-control8-nowhere-#{System.unique_integer([:positive])}"

refute runtime_row_present?(runtime_id)
refute on_foreign(owner, fn -> runtime_row_present?(runtime_id) end)
```

The broadcast still goes through the real `Tasks.broadcast_board/1` fan-out from
the independently-owned connection, and the assertion is unchanged:
`await_drop!(runtime_id, :foreign_connection)`.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test $TESTFILE
```

```
Running ExUnit with seed: 192028, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

.....
Finished in 0.3 seconds (0.00s async, 0.3s sync)
5 tests, 0 failures
```

**Verdict: BEHAVED AS PREDICTED. This control's predicted outcome is a pass,
not a failure** — the stage asks that the `:foreign_connection` drop "must fire
and be received", and it did.

Why a green run is evidence here and not the absence of it: `await_drop!/2` is a
blocking selective receive that `flunk/1`s on timeout, matching on
`%{runtime_id: ^runtime_id, reason: :foreign_connection}`. Green means the drop
was **received**, with that runtime_id, through the production broadcast path —
not that nothing happened. And the assertion is demonstrably falsifiable: §19
(control 3) is the same assertion failing when the guard that produces the drop
is deleted.

That is what this control exists to establish. Every "no ownership error was
raised" claim in this file is underwritten by the harness being able to observe
a reconnect **arriving at the callback at all**, independent of whether it
succeeds. Without it those claims would be unfalsifiable — satisfied identically
by a broadcast that never reached the watcher.

## 25. Tally

| # | Mutation | Predicted | Observed | Verdict |
|---|---|---|---|---|
| 1 | revert stage-2 fix (3 files) | file goes red, matching §13.2 | 5 tests, 5 failures, message + frame identical | detonated as predicted |
| 2 | delete precondition A | a named assertion fails | 5 tests, 1 failure (`:connection_unowned` await) | detonated as predicted |
| 3 | delete precondition B | a named assertion fails | 5 tests, 2 failures (both `:foreign_connection` awaits) | detonated as predicted |
| 4 | `connection_owned? -> false` | half 2's dispatch assertion MUST fail | 5 tests, 3 failures, incl. half 2's dispatch assertion | detonated as predicted |
| 5 | `redispatch_for_runtime -> :ok` | half 2 fails, half 1 passes | 5 tests, 1 failure — half 2 only | detonated as predicted |
| 6 | delete `send(pid, :dispatch)` only | half 2 fails, half 1 passes | 5 tests, 1 failure — half 2 only | detonated as predicted |
| 7 | delete `sync/0` barrier, 10 runs | green 10/10 ⇒ barrier not load-bearing | green 10/10 — but paired form shows 5/5 vs 0/10 | **did not detonate**; barrier IS load-bearing, §23.1 |
| 8 | arm 2 → runtime with no row anywhere | `:foreign_connection` drop fires and is received | 5 tests, 0 failures; drop received | behaved as predicted (predicted outcome is a pass) |

**Count: 6 mutations produced test failures (controls 1–6). 1 non-detonation
(control 7 as specified). 1 control whose predicted outcome is a pass and which
was observed (control 8).**

Distinct assertions in the file that were shown to be individually load-bearing:
`await_drop!(_, :connection_unowned)` (§18), `await_drop!(_, :foreign_connection)`
at two sites (§19), half 2's `assert_receive {:dispatched, _}` (§20, §21, §22),
and the mirror's `refute_received {:dispatched, _}` (§23.1). That is every
assertion in the file except the `assert_watcher_survived/3` belt, which §12.1
already records as a belt and which no control moved.

**Not measured, and not claimed:** no control here reproduces a
`DBConnection.OwnershipError` through this file's assertions. §16.1 explains why
that is structurally impossible rather than an omission, and §3.3 holds the
ownership-shape evidence separately.

`git diff --stat 446283d4` is empty over `lib/` and `test/`; the only change
this stage makes to the tree is this note.

# Stage 5 — the sibling sweep

`git diff --stat da483e85` is empty over `lib/` and `test/`; the only change this
stage makes to the tree is this note. Every mutation below (a `test_helper.exs`
restart probe, a `local_runner.ex` timing control) was reverted before commit;
`git status --short` was clean at each revert and is clean now.

## 26. Method — the sweep is measured, not read

Three instruments, all run on this tree at `da483e85`:

**(a) A process census under `MIX_ENV=test`.** A throwaway
`test/support/census_probe.exs` run with `mix run` after the application boots,
printing `Process.whereis/1` for every module in scope plus `:ets.info/1` for the
named tables. This answers the "runs in test?" column with a fact instead of a
config read — a `config/test.exs` flag is evidence about intent, the live process
table is evidence about behaviour.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 MIX_ENV=test \
    mix run test/support/census_probe.exs

--- process census (MIX_ENV=test, application started) ---
Platform.Chat.AttentionRouter               => nil
Platform.Agents.ContextBroker               => #PID<0.446.0>
Platform.Chat.ContextPlane                  => #PID<0.457.0>
Platform.Responsibilities.Router            => nil
Platform.Orchestration.TaskRouterWatcher    => nil
Platform.Meetings.MeetingNotifier           => nil
Platform.Federation.DeadLetterReplay        => #PID<0.455.0>
Platform.Federation.RuntimePresence         => #PID<0.454.0>
Platform.Orchestration.LeaseManager         => #PID<0.451.0>
--- ETS tables owned by singletons ---
:orchestration_lease_manager => owner=#PID<0.451.0> protection=:public named=true
:suite_context_plane         => owner=#PID<0.457.0> protection=:public named=true
:chat_attention_heartbeat    => undefined
```

**(b) A singleton-restart probe over a full suite run.** A temporary
`test_helper.exs` addition monitored the five processes that DO run in test and
appended every `:DOWN` to `/tmp/stage5_singleton_restarts.log`, re-monitoring across
restarts. This exists because §11's carried `LeaseManager` finding rests on "any
restart of that singleton wipes the table" — and whether a restart is *reachable*
is a measurable property, not an assumption. Stage 4 falsified the max-restart
cascade the same way.

**(c) A full-suite run with per-violation attribution.** `mix test`, log captured,
then each `Client #PID<…> is still using a connection from owner` block attributed
to the `Platform*` module named in its stack.

**Contention status: UNCONTENDED.** `ps -eo args | grep 'mix test'` returned nothing
before the run. Stage 4's reading applies and is worth restating: contention can
only manufacture timing failures, never remove them, so an uncontended green is the
*weaker* of the two. The one failure below is therefore not explainable by load from
a sibling suite.

```
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test
Finished in 265.3 seconds (58.9s async, 206.3s sync)
21 doctests, 9796 tests, 1 failure, 3 skipped (2 excluded)
```

9796, not stage 1's 9791: stage 3 added the 5-test reconnect regression file.

A **second, clean full-suite run** on the final tree — probe reverted, note in place
— is this stage's `test_pass` evidence, and it is also the second data point on §37's
rate:

```
$ ps -eo args | grep 'mix test'      # nothing — UNCONTENDED again
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test
Finished in 243.5 seconds (61.8s async, 181.6s sync)
21 doctests, 9796 tests, 0 failures, 3 skipped (2 excluded)
```

So the `LocalRunner` race of §37 is **1 failure in 2 full-suite runs**, and 0 in 20
isolated runs of its own file. Both full runs uncontended, which by stage 4's reading
makes the green the weaker of the two results and the red the load-bearing one.

## 27. THE TABLE

Columns as specified. "Runs in test?" is from instrument (a). "Violations" is from
instrument (c) — count of attributed `still using a connection from owner` blocks in
one full run, and it is the column that turns two pre-verdicts over.

| # | module | callback | runs in test? | Repo? | guard mechanism | mutates global non-transactional state? | violations | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | `TaskRouterWatcher` | `handle_info({:task_created \| :task_updated, task})` → `handle_task_event/2` (`:176`, `:320`) | **only per-case** (`start_supervised!` in 5 files); global gated off | yes — `task_row_visible?/1`, `resolve_runtime_for_task/1`, `list_should_run_tasks/0` | precondition A `connection_owned?/0` + precondition B `row_visible?/2`, then `guarded/3` | **yes** — Registry, supervised `TaskRouter` children, `LeaseManager.clear/1` via terminate | **0** (was 113) | **CLEAN** — fixed in stage 2; `019fb977`'s hunks, zero touched here |
| 2 | `TaskRouterWatcher` | `handle_info({:runtime_reconnected, id})` → `handle_runtime_reconnected/1` (`:181`, `:339`) | only per-case | yes — `runtime_row_visible?/1` (`Repo.exists?`), `redispatch_for_runtime/1` (`Repo.all`) | preconditions A+B, then `guarded/3`; `redispatch_for_runtime/1` also rescues `OwnershipError` + catches `:exit` | **yes** — `send(pid, :dispatch)` into a live router | **0** (was 8) | **CLEAN** — this task's own callback; stage 3 test + 8 stage-4 controls |
| 3 | `TaskRouterWatcher` | `runtime_row_visible?/1` (`:364`) | only per-case | yes — `Repo.exists?` on `AgentRuntime` | `sandbox_pool?/0` gate (production-inert by construction) + `guarded/3` defaulting `false` | no | **0** | **CLEAN** — controls 3 and 8 both detonate on it (§19, §24) |
| 4 | `TaskRouterWatcher` | `redispatch_for_runtime/1` (`:995`) | only per-case | yes — `list_should_run_tasks/0` | own `rescue OwnershipError` + `catch :exit`, inside caller's `guarded/3` | **yes** — `send(pid, :dispatch)` | **0** | **CLEAN** — controls 5 and 6 detonate independently (§21, §22) |
| 5 | `TaskRouterWatcher` | `active_lease_present?/2` (`:1041`) | only per-case | **yes, and it WRITES** — `current_lease_for_task_runtime/2` runs `Repo.update_all` (`expire_stale_leases/2`, `runtime_supervision.ex:449-468`) before its `Repo.one` | inherited: inside `redispatch_for_runtime/1`'s rescue, inside `guarded/3` | no — the write is a transactional `ExecutionLease` UPDATE, sandbox-scoped | **0** | **CLEAN** — but see §28: the write is undocumented at the call site |
| 6 | `TaskRouterWatcher` | `handle_info(:reconcile, _)` (`:186`) | **yes** — 4 direct `send(watcher_pid, :reconcile)` sites in `task_router_watcher_test.exs` (291, 312, 357, 405); self-timer off via `:task_router_watcher_reconcile, false` | yes — `reconcile/0` + 4 sweeps, all `Repo.all` | `safe_reconcile/0` (`:1114`) rescues + catches; each of the 4 sweeps has its own independent `try` | **yes** — starts and stops routers: Registry, supervised children, `LeaseManager.clear/1` | **0** | **CLEAN BY UNREACHABILITY, NOT BY CONSTRUCTION** — see §29. It is the one watcher entry point with **no precondition gate at all** |
| 7 | `TaskRouterWatcher` | `handle_info(_msg, state)` catch-all (`:289`) | yes | no | none needed | no | **0** | **CLEAN** — `{:noreply, state}`, no call, no side effect |
| 8 | `TaskRouterWatcher` | `handle_call(:sync, …)` (`:292`) | yes | no | none needed | no | **0** | **CLEAN** — pure reply; it is the stage-3 barrier, load-bearing per §23.1 |
| 9 | `Platform.Chat.AttentionRouter` | `handle_info({:telemetry_message_posted, …})` (`:154`) | **NO** — `whereis` = `nil`, `:start_attention_router, false` | yes (`Repo.get`, `Repo.exists?`, `Repo.all`) — would be, if it ran | n/a | would be — `:chat_attention_heartbeat` ETS (`:protected`) | **0** | **CLEAN by non-participation** — pre-verdict CONFIRMED. Its `data_case.ex` entry and its `:__drain__` are dead code (§30) |
| 10 | `Platform.Agents.ContextBroker` | `handle_call({:share_context, …})` / `({:promote_delta, …})` (`:71`, `:113`) | **yes** — `#PID<0.446.0>` | **yes** — `Repo.insert` at `:220` and `:263`, executed in the broker's own process | **none** — no rescue, no precondition | no | **0** | **CLEAN by call shape** — see §31 for the reachability argument and the single condition that would break it |
| 11 | `Platform.Agents.ContextBroker` | `init/1` (`:68`) | yes | no — `{:ok, %{}}` | none needed | no | **0** | **CLEAN** — no boot query, so no restart-time Repo hazard |
| 12 | `Platform.Chat.ContextPlane` | `handle_cast({:update_agent_state, …})` (`:104`) | **yes** — `#PID<0.457.0>` | **no** — zero occurrences of `Repo` in the whole module | none needed | **yes** — `:suite_context_plane`, `:named_table, :public`, created in its own `init/1` (`:98`) | **0** | **CLEAN for this flake; carries the §11 ETS-lifetime pattern** (§32) |
| 13 | `Platform.Chat.ContextPlane` | `handle_info(_msg, _)` / `handle_call(:__drain__, …)` (`:112`, `:116`) | yes | no | none needed | no | **0** | **CLEAN** — and the `:__drain__` call `data_case.ex` makes buys nothing (§30) |
| 14 | `Platform.Chat.ContextPlane` | `handle_telemetry_event/4` (`:136`) | yes | **yes** — `fetch_message_preview/1` → `Platform.Chat.get_message/1` (`:229`) | none | yes — `:ets.insert` into the public table | **0** | **CLEAN, with a correction to its own framing** — this runs in the *emitting* process, never in ContextPlane's; see §32 |
| 15 | `Platform.Responsibilities.Router` | `init/1`, `handle_info(:tick \| {topic,_} \| {event,_})`, `handle_cast({:webhook_fire, …})` | **NO globally** — `whereis` = `nil`, `:start_responsibility_router, false`; per-case instances only | yes — `walk_registry/0` at boot, Repo on every fire path | none at the callback boundary | yes — fires responsibilities, stamps the registry | **1** (from a per-case instance: `safe_assignee_for/1`, `safe_stamp_last_fire/2`) | **CLEAN by non-participation globally.** No pre-verdict existed; it is the **strongest precedent for stage 2's fix**, stronger than `MeetingNotifier` — §33 |
| 16 | `Platform.Meetings.MeetingNotifier` | `handle_info({:meeting_started, %Meeting{}})` (`:101`) → `fan_out/1` (`:145`) | **NO** — `whereis` = `nil`, `:start_meeting_notifier, false` | yes, and **completely unguarded** — `Repo.preload` (`:146`), `Chat.list_participants` (`:156`) | **none whatsoever** | yes — sends push payloads / writes inbox rows | **0** | **CLEAN by non-participation** — pre-verdict CONFIRMED, including the planner's own caveat that this is a *weak* precedent |
| 17 | `Platform.Federation.DeadLetterReplay` | **`handle_cast({:drain, runtime_id}, _)`** (`:204`) → `safe_drain/3` → `safely/1` → `drain/2` | **yes** — `#PID<0.455.0>`, and it is cast into from `runtime_channel.ex:105` in the same `join/3` body that broadcasts `{:runtime_reconnected, _}` | **yes** — `DeadLetters.pending_for_runtime/1` (`Repo.all`) at `dead_letter_replay.ex:300` | `safely/1` (`:272`) — `rescue exception` + `catch :exit` | no (its `%{drains: …}` counter is process state, not shared) | **6** | **DEFECTIVE.** Pre-verdict FALSIFIED. Not fixed here — §34 gives the evidence, the fix design, and the named reason |
| 18 | `Platform.Federation.DeadLetterReplay` | `handle_info(:prune, _)` / `handle_info(:rollup, _)` (`:219`, `:236`) | yes, but the timers are 6 h / 24 h — cannot fire in a 265 s run; reachable only by a direct `send` (`dead_letter_replay_test.exs:582, 607`) | yes | `safely/1` | no | **0** | **CLEAN** — pre-verdict CONFIRMED for these two clauses specifically |
| 19 | `Platform.Federation.DeadLetterReplay` | `handle_call({:drain, …})` / `({:drain_count, …})` (`:210`, `:215`) | yes | yes (`{:drain, …}` only) | `safely/1` | no | **0** | **CLEAN** — synchronous, so the caller's sandbox context is live for the whole call |
| 20 | `Platform.Federation.RuntimePresence` | `Agent.update/2` and `Agent.get/2` — `track/1`, `untrack/1`, `touch/1`, `online?/1`, `status/1`, `list_online/0`, `list_all/0` | **yes** — `#PID<0.454.0>` | **no** — zero `Repo`, zero `send_after`, zero PubSub in all 71 lines | n/a | **yes** — the presence map is process state, wiped on restart, and shared across every test | **0** | **CLEAN, pre-verdict CONFIRMED** — with a cross-test-bleed caveat in §35 |
| 21 | `Platform.Orchestration.LeaseManager` | `init/1` (`:141`) and every `handle_call` (`:326`–`:420`) | **yes** — `#PID<0.451.0>` | **no** — zero `Repo` in the module | n/a | **YES — `:orchestration_lease_manager`, `:named_table, :public`, created in its own `init/1`; `:public` tables die with their owner** | **0** | **REAL MECHANISM, MEASURED UNREACHED — see §36 for the verdict and for a correction to §11's attribution** |

**Every row is filled. Fifteen of the twenty-one come back CLEAN, and they are
written down for the reason the stage gave: so the next agent does not re-derive
them.** Exactly one row is DEFECTIVE (#17). One row (#21) is a real mechanism with
zero measured reach. One row (#6) is clean only because nothing currently reaches it.

### 27.1 Per-violation attribution for the whole run, so the table's zeroes are readable

39 attributed `still using a connection from owner` blocks. (The `owner … exited`
Postgrex-disconnect line — the metric stage 1's 212/72/78/95 census used — appears
70 times in the same log. **They are different metrics and must not be compared to
each other.** Stage 1's numbers are the disconnect count; this table is the
attributed-client count.)

| module in the violating stack | blocks |
|---|---|
| `Task.Supervised` (fire-and-forget children) | 15 |
| `PlatformWeb.TasksLive` | 10 |
| **`Platform.Federation.DeadLetterReplay`** | **6** |
| `PlatformWeb.MeetingLive` | 4 |
| `PlatformWeb.ChatLive` | 4 |
| `Platform.Orchestration.TaskRouter` (`terminate/2`) | 2 |
| `Platform.Responsibilities.Router` (per-case instance) | 1 |
| `Platform.Meetings.IntentQueue.Server` | 1 |
| `Platform.Chat.Canvas.Server` | 1 |
| unattributed | 1 |
| **`Platform.Orchestration.TaskRouterWatcher`** | **0** |

`TaskRouterWatcher` at 0 is now confirmed on a **fourth** independent full run
(stage 2 measured three). Of everything this stage swept, **`DeadLetterReplay` is
the single largest contributor** — it is third overall behind `Task.Supervised` and
`TasksLive`, both of which stage 1 already recorded as pre-existing and out of scope.

## 28. Row 5 — `active_lease_present?/2` writes, and its name does not say so

`active_lease_present?/2` reads as a predicate. It calls
`RuntimeSupervision.current_lease_for_task_runtime/2`, whose **first statement** is
`expire_stale_leases(Repo, task_id: …, runtime_id: …)` — a `Repo.update_all` that
flips every matching lease to `"expired"` (`runtime_supervision.ex:449-468`).

So a runtime reconnect performs a DB **write** before it decides whether to
redispatch. That is correct behaviour (expiring stale leases is what makes the
predicate meaningful) and it is fully inside the stage-2 preconditions and the
`guarded/3` envelope, so it does not violate. Recording it because a future reader
auditing "which reconnect paths mutate state" will scan for `Repo.insert|update|
delete` and this one is spelled `?`.

## 29. Row 6 — the `:reconcile` handler is the one gate-less entry point

The stage flagged `safe_reconcile/0` as "the interesting one" and it is, but not
for the asymmetry the description guessed at. The four sweeps beside it each having
their own `try` is fine — that is per-sweep degradation, deliberate, and each
returns a shaped zero map so the `Logger.info` interpolation below cannot crash.

The real asymmetry is upstream. `handle_task_event/2` and
`handle_runtime_reconnected/1` both open with **two preconditions before any global
state is touched** — `connection_owned?/0` and a row-visibility probe — and the
comment block at `:294-319` explains at length why the guard must sit there rather
than downstream. `handle_info(:reconcile, _)` has **neither**. It goes straight to
`safe_reconcile/0` → `reconcile/0` → `list_should_run_tasks/0`, and then starts and
stops routers — Registry entries, supervised children, `LeaseManager.clear/1` via
`terminate` — off the result of a `Repo.all` that, on a foreign connection, returns
*another test's* task list.

**What would have to be true for this to fail?** Exactly one of:

1. `:task_router_watcher_reconcile` is set back to `true` in test, or
2. a per-case watcher outlives the test that started it (it cannot today —
   `start_supervised!` ties it to the case), or
3. someone sends `:reconcile` to a watcher from outside its owning test.

None hold on this tree, which is why the column reads 0. But "clean" here means
*unreachable*, not *defended* — the distinction stage 4 had to make for control 7.

**I am deliberately NOT adding the two preconditions to this clause**, and the
reason is this stage's own directive plus §5's measurement: `SandboxGuard` appeared
in 289 violation stacks because its preconditions are themselves Repo calls, so
adding a third guarded entry point buys a third way to be inside the guard when
Postgrex kills the connection. The right remedy for row 6 is the one stage 2
already applied to the process as a whole — do not run it — and that is in force.

## 30. `data_case.ex`'s `supervised_with_repo` list is three-quarters inert

Confirmed against the live census, and it goes further than stage 1 §6:

| entry | process exists in test? | touches Repo in its own process? | so the `Sandbox.allow` is… |
|---|---|---|---|
| `Platform.Chat.AttentionRouter` | **no** | (yes, if it ran) | never executed — `if pid = Process.whereis(name)` is false |
| `Platform.Agents.ContextBroker` | yes | **yes** | **the one entry that does real work** |
| `Platform.Chat.ContextPlane` | yes | **no** (zero `Repo` in the module) | executed, but pointless |
| `Platform.Responsibilities.Router` | **no** | (yes, if it ran) | never executed |

And the `on_exit` drain loop (`data_case.ex:98`) iterates
`[AttentionRouter, ContextPlane]`: the first never runs, and the second has no Repo
call to wait for — its telemetry handlers execute in the *emitter's* process
(§32). So the drain whose stated purpose is "their Repo calls completed before the
sandbox owner exits" currently waits for nothing. `Platform.SandboxHelpers.
drain_or_warn/0` on the line below is the part that still does the real work.

**Not changed here.** `data_case.ex` is inside this stage's file grant, so this is a
choice and not an omission: stage 1 §6 recorded the `AttentionRouter` half and
concluded "worth deleting or re-enabling deliberately, in its own change", and the
right resolution is not a delete — it is a decision about whether `AttentionRouter`
and `Responsibilities.Router` should be *running* in test. Deleting the entries now
would erase the evidence that the question exists.

## 31. Row 10 — why `ContextBroker` is clean, and the one thing that would break it

`ContextBroker` is a supervised singleton that calls `Repo.insert` in its own
process (`:220`, `:263`) with no rescue and no precondition. That is the same
*ingredients* as the watcher. It has zero violations, and the reason is not luck:

* Its **only** entry points are `GenServer.call/3` (`share_context/5`,
  `promote_delta/3`). It subscribes to no PubSub topic, attaches no telemetry
  handler and arms no timer — `init/1` is literally `{:ok, %{}}`. So it never acts
  unbidden. A caller is always blocked on it, which means the caller's sandbox
  context is guaranteed live for the whole call. The watcher's defect required a
  *broadcast* entry point; `ContextBroker` has none.
* It is exercised by exactly **one** test file, `context_broker_test.exs`, which is
  `async: false`.

**What would have to be true for it to fail:** two `async: true` tests calling it
concurrently. `data_case.ex` would `Sandbox.allow` the same singleton pid onto two
different connections; the second `allow` returns `{:already, :allowed}` and the
return value is discarded, so test B's call would silently execute on test A's
connection. That is one `async: true` away, from a single test file. Recorded so a
future author of a second caller sees the constraint before the flake does.

## 32. Row 12/14 — `ContextPlane` carries §11's ETS pattern and no Repo at all

Two separate findings that are easy to conflate.

**It owns a second `:named_table, :public` ETS table.** `:suite_context_plane`,
created in its own `init/1` at `context_plane.ex:98`, owner `#PID<0.457.0>` per the
census. Same lifetime property as `:orchestration_lease_manager`: `:public` tables
die with their owner, so a restart of `ContextPlane` silently empties every space's
cached agent state, canvases and activity ring. The stage description named
`:orchestration_lease_manager` as the one instance of this pattern in scope; there
are **two**, and neither `LeaseManager` nor `ContextPlane` is defended against it.
`ContextPlane` is the less severe of the two — its contents are a cache with a
rebuild path — but it belongs in the same ticket, because a fix that hardens one
table's lifetime and not the other is the partial fix this stage exists to prevent.

**Its Repo call does not run in its process.** `handle_telemetry_event/4` calls
`fetch_message_preview/1` → `Platform.Chat.get_message/1`, which is a Repo read.
But `:telemetry.attach_many/4` handlers execute **synchronously in the process that
calls `:telemetry.execute/3`**, so that read happens in the publisher — in test,
the test process itself, which owns its connection. This is exactly why the module
has a Repo call and zero violations. It is also why `data_case.ex`'s `:__drain__`
against `ContextPlane` cannot be protecting anything: the work it would drain was
never on `ContextPlane`'s queue.

Note the contrast with `Responsibilities.Router`, which attaches a telemetry handler
that deliberately *forwards into its own mailbox* (`router.ex:427`) so the matching
work happens on its process and not the publisher's. Same primitive, opposite
choice, opposite ownership consequence.

## 33. Row 15 — `Responsibilities.Router` is the precedent the ticket was looking for

The stage description flagged `MeetingNotifier` as a *weak* precedent for "must a
lifecycle-subscribing singleton run in test?" — correctly, because a push-notifier
is not architecturally like the watcher.

`Platform.Responsibilities.Router` is. It is a supervised singleton that at `init/1`
runs `walk_registry/0` (a Repo read), subscribes to N PubSub topics
(`subscribe_event_topics/1`, `:513`), attaches a telemetry handler that forwards
into its own mailbox (`:427`), arms a repeating `:tick` (`schedule_check/1`,
`:503`), and does Repo work on every fire path. Feature for feature, that is
`TaskRouterWatcher`.

And it is **already gated off in test** — `:start_responsibility_router, false`
(`config/test.exs:138`), honoured at `application.ex:293` — with a comment giving
the same reason stage 2 gave: *"Tests start per-case instances under the DataCase
sandbox."* Its per-case instances still account for 1 violation block in this run.

So the precedent stage 2's option A rested on was not one example, it was three
(`MeetingNotifier`, `AttentionRouter`, `Responsibilities.Router`), and the strongest
of them was never cited. The registry sibling `:start_responsibilities_registry`
(`:133`) is off for the same reason. This is worth stating because it retires the
"is start-gating in test a hack?" question with a count.

## 34. Row 17 — `DeadLetterReplay` is DEFECTIVE. The pre-verdict is falsified

**The pre-verified expectation was CLEAN, on the grounds that it "wraps every Repo
path in `safely/1` (`dead_letter_replay.ex:274-280`, catching both `rescue
exception` and `catch :exit`)". The measurement says the wrapper is irrelevant to
whether the violation happens.** Verbatim, from the run:

```
Client #PID<0.468.0> (Platform.Federation.DeadLetterReplay) is still using a
connection from owner at location:

    :erlang.port_command/3
    :prim_inet.send/4
    (postgrex 0.22.0) lib/postgrex/protocol.ex:3359: Postgrex.Protocol.do_send/3
    …
    (ecto 3.13.5) lib/ecto/repo/queryable.ex:19: Ecto.Repo.Queryable.all/3
    (platform 0.1.0) lib/platform/federation/dead_letter_replay.ex:300: …DeadLetterReplay.drain/2
    (platform 0.1.0) lib/platform/federation/dead_letter_replay.ex:273: …DeadLetterReplay.safely/1
    (platform 0.1.0) lib/platform/federation/dead_letter_replay.ex:262: …DeadLetterReplay.safe_drain/3
    (platform 0.1.0) lib/platform/federation/dead_letter_replay.ex:204: …DeadLetterReplay.handle_cast/2
    (stdlib 6.2.2) gen_server.erl:2371: :gen_server.try_handle_cast/3
```

`safely/1` is at line **273 of the stack**, i.e. the violating query is running
*inside* it. This is §5's structural finding reproduced verbatim on a second module:
a `rescue` runs after the failure, and the failure here is Postgrex force-
disconnecting a pooled connection that a *different* test is holding. Wrapping
converts "this process crashes" into "some other test fails"; it does not prevent
the violation. **6 blocks in one full run — the largest of any module this stage
swept, and third overall.**

**Why it is the watcher's twin and not a coincidence.** `runtime_channel.ex`'s
`join/3` does both of these, eight lines apart:

```elixir
# line 97
Platform.Tasks.broadcast_board({:runtime_reconnected, runtime_id})
# line 105
Platform.Federation.DeadLetterReplay.schedule(runtime_id)
```

One reconnect, two async singletons, both doing `Repo.all` off a connection they do
not own. Stage 2 fixed the first. The second is the same defect on the same trigger,
and the violating clause is precisely the `cast` — `handle_cast/2` at `:204`. The
`call` variant (`replay_now/2`, row 19) has zero violations for the same reason
`ContextBroker` does: the caller stays blocked, so its sandbox context is live.

**NOT FIXED IN THIS STAGE. The reason, plainly.** The stage-2-shaped fix is exact
and I am confident in it — `maybe_add_dead_letter_replay/1` in `application.ex`
mirroring `maybe_add_meeting_notifier/1` at `:360-368`, plus `config :platform,
:start_dead_letter_replay, false` in `config/test.exs`. Both files are inside this
stage's grant. **The test conversion is not.** Three files depend on the global
instance, and one of them cannot be converted mechanically:

* `dead_letter_replay_test.exs` — 20+ `replay_now/2`, `schedule/1`, `drain_count/1`
  sites plus two `send(Process.whereis(DeadLetterReplay), …)`. Mechanical
  (`start_supervised!` in `setup`), but 20+ sites.
* `runtime_channel_test.exs:174, 183, 190` — asserts `drain_count/1` against the
  global after a real channel join. Mechanical.
* **`dead_letters_test.exs:705`, `"loss_summary/0 is unchanged across a
  DeadLetterReplay restart"` — its entire premise is `GenServer.stop` on the
  application-supervised singleton followed by `wait_for_restart/1`.** Under
  `start_supervised!` the child is `:temporary` and never restarts, so converting it
  does not preserve what it tests; it needs its own supervisor, which is a redesign
  of a durability test belonging to task `019fa56b-ca2d`.

This stage's grant is `handle_runtime_reconnected/1`, `runtime_row_visible?/1`,
`redispatch_for_runtime/1`, `active_lease_present?/2`, the `{:runtime_reconnected,
_}` clause, `application.ex`, `config/test.exs`, `data_case.ex`. Stage 2's
equivalent change came with an explicit enumeration of the five watcher test files
it was allowed to convert; there is no such grant here, and this stage's own
forbidden list bars the kind of test churn the conversion needs. I am following the
precedent stage 1 §9.1 set for the two sibling `/tmp` files: **the defect is
measured, the fix is designed, the change is not made, and it is named here so it
is a ticket and not a silence.**

Ready to execute on a one-line grant. It should NOT ride along on this task's
branch — `019fb977` is at review on adjacent files.

## 35. Row 20 — `RuntimePresence` is clean on Repo and dirty on lifetime

Pre-verdict CONFIRMED and then some: all 71 lines read, zero `Repo`, zero
`send_after`, zero PubSub, `use Agent`. It cannot produce an ownership violation
because it has no query to produce one with. 0 blocks.

The caveat it earns anyway: its presence map is **global mutable state shared across
every test in the run**, and 37 `track/1` / `untrack/1` call sites across 9 test
files write to it, of which only 14 are `untrack`. A test that tracks a runtime and
does not untrack leaves that runtime `online?` for every later test — and
`DeadLetterReplay.drain/2` gates its entire Repo body on
`RuntimePresence.online?/1` (`:285`). So presence residue is one of the inputs
that decides whether row 17 fires. Not a defect on its own; a coupling worth
knowing before someone "cleans up" the untracks.

The module's own `touch/1` docstring already documents the restart hole ("recovers
the map after this Agent process crashes/restarts"), so the lifetime property is
known and deliberately self-healed. Zero restarts measured (§36).

## 36. Row 21 — `LeaseManager`'s `:public` ETS table: REAL, UNREACHED, and §11's attribution needs correcting

This is the row §11 carried forward, and it deserves three separate answers because
it mixes three separate claims.

### 36.1 The mechanism is real, and it scores "yes" for a reason that has nothing to do with Repo

Confirmed by reading and by the census. `LeaseManager` has **zero `Repo` calls in
the entire module**. It creates `:orchestration_lease_manager` as `:named_table,
:public` inside its own `init/1` (`lease_manager.ex:141-152`), and its own comment
at `:144` states the property: *"`:public` tables die with their owner."* The census
confirms `owner=#PID<0.451.0>`, i.e. the LeaseManager process itself, not a
supervisor or `:ets` heir.

**It is the only row in the table that scores "yes" on the last column while
scoring "no" on Repo, and that is worth saying out loud** — the entire sweep is
framed around DB ownership, and this defect has nothing to do with the database. A
restart of that singleton wipes every task's lease row at once. Nothing in the
module defends against it: no `heir` option, no re-hydration, no supervisor-owned
table. The `init/1` branch that tolerates a pre-existing table is defensive against
tests, not against its own restart.

### 36.2 It is UNREACHED on this tree — measured, not assumed

Instrument (b), over the full 265-second run:

```
$ cat /tmp/stage5_singleton_restarts.log
probe start ~U[2026-07-31 20:56:46.202481Z]
Platform.Federation.DeadLetterReplay DOWN gen=0 pid=#PID<0.468.0>
  reason=:normal at ~U[2026-07-31 20:58:48.974815Z]
```

**One line. `LeaseManager`: zero restarts. `ContextPlane`: zero. `ContextBroker`:
zero. `RuntimePresence`: zero.** The single restart in the whole suite is
`DeadLetterReplay`, `reason=:normal`, and it is not an accident — it is
`dead_letters_test.exs:705` deliberately calling `GenServer.stop(pid, :normal)` to
assert counter durability across a restart (§34).

So the restart-wipes-the-table mechanism is **latent, not active**. This is the same
call stage 4 made on the max-restart cascade: a mechanism you can describe is not a
mechanism that fires, and building a verdict on an unmeasured one is how a note
misleads its next reader.

The one live wipe path is `:ets.delete_all_objects(:orchestration_lease_manager)` in
the `on_exit` of `lease_manager_test.exs:37` and `lease_manager_redispatch_test.exs:40`
— a global wipe of every task's row, from inside a test. It is safe **only** because
both files are `async: false`, and ExUnit runs sync modules strictly after all async
modules have finished, one at a time. Flip either file to `async: true` and that
`on_exit` races every other test in the suite. (This stage's forbidden list bars
`async` flips, which is now a load-bearing prohibition rather than a stylistic one.)

### 36.3 §11's attribution to `task_router_stage_isolation_test.exs:307` does not survive checking

§11 states the failure was `LeaseManager.get(task_id) == nil` at
`task_router_stage_isolation_test.exs:307`. Line 307 on this tree is:

```elixir
assert %{status: "blocked", stage_id: stage_a_id} =
         RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)
```

That is a **Postgres read of the `execution_leases` table**
(`runtime_supervision.ex:121-131`, `Repo.one/1`). It does not touch `LeaseManager`
or ETS at all. The module is right; the line is wrong by about 22.

The real `LeaseManager.get/1` assertions in that file are lines **329** and **347**,
in the next test. And line 329 has a sufficient mechanism that is not the ETS table:

```elixir
await_attention!()          # :323
Process.sleep(100)          # :324
…
assert %{stage_id: _, ack_at: nil, no_ack_fired?: false} =
         LeaseManager.get(task.id)    # :328-329
```

`await_attention!/1` returns when the router broadcasts attention, which
`task_router.ex` does inside `ExecutionSpace.post_engagement/3` at `:1302`.
`LeaseManager.record_dispatch/4` — the call that creates the row line 329 asserts on
— runs at `:1422`, reached via `arm_liveness_timers/3` at `:1312`, i.e. **strictly
after** the broadcast the test woke on. The gap between them is bridged by a bare
`Process.sleep(100)`, and that gap contains `post_log/2` and `post_engagement/3`,
both of which do DB writes. Under load, 100 ms is a guess that can be short — and
`LeaseManager.get/1` returns `nil`.

That mechanism predicts exactly the observed signature: **fails at seed 0, passes on
a re-run at the identical seed on the identical tree.** A sleep race is
seed-independent and load-dependent. An ETS wipe by restart would also be
seed-independent, but zero restarts were measured, so it is not available as an
explanation.

**Verdict, stated plainly as the stage asked:**

* The `:public`-ETS lifetime property is **REAL and undefended**, it affects **two**
  tables (`:orchestration_lease_manager` and `:suite_context_plane`, §32), and it is
  **OUT OF SCOPE for this task** — no Repo surface, no sandbox ownership, nothing to
  do with `handle_runtime_reconnected/1`, and its fix (an ETS `heir` or a
  supervisor-owned table) is an orchestration-durability change, not a test-isolation
  one. **It should be its own ticket, covering both tables.**
* It is **NOT the cause of the failure §11 attributed to it.** Measured 0 restarts.
  The `Process.sleep(100)` barrier at `task_router_stage_isolation_test.exs:324` is
  the better-supported mechanism, and the fix is the barrier stage 3 already
  introduced for the watcher (`TaskRouterWatcher.sync/0`) — control 7 measured that
  substituting a real barrier for a sleep is worth **5/5 caught vs 0/10** (§23.1).
* **That file belongs to `019fb977`, which is at task-level review.** Reported, not
  touched — zero hunks, per this stage's scope.

## 37. Unrequested finding: a THIRD mechanism in `test/platform/execution/`, in production code

The full-suite run's single failure was not any module in the sweep, and it is worth
the space because this ticket's title is *localize the execution-test flake* and this
is a third mechanism in that directory, distinct from stage 1's two.

```
1) test LocalRunner stop/kill force_stop after wrapper exit is safe (idempotent)
   (Platform.Execution.LocalRunnerTest)
   test/platform/execution/local_runner_test.exs:209
   ** (exit) exited in: GenServer.call(#PID<0.30507.0>, :provider_ref, 5000)
       ** (EXIT) normal
   code: LocalRunner.spawn_run(run,
   stacktrace:
     (elixir 1.19.5) lib/gen_server.ex:1142: GenServer.call/3
     (platform 0.1.0) lib/platform/execution/local_runner.ex:54: …LocalRunner.spawn_run/2
     test/platform/execution/local_runner_test.exs:217: (test)
```

**Mechanism, exactly.** `LocalRunner.spawn_run/2` ends with

```elixir
{:ok, LocalProcessWrapper.provider_ref(wrapper)}   # local_runner.ex:54
```

and `provider_ref/1` is `GenServer.call(server, :provider_ref)`
(`local_process_wrapper.ex:57`). The wrapper opens its `Port` in `init/1`
(`:99`), so the child process is already running when `start_link/1` returns. When
the child exits, the wrapper receives `{port, {:exit_status, _}}` and answers
`{:stop, :normal, state}` (`local_process_wrapper.ex:185`). For a command that exits
immediately — this test passes `exit0` — the wrapper can therefore be **gone before
the caller issues its very next call**, and the `GenServer.call` exits `:normal` into
the caller. `spawn_run/2` has no `try` and no `:noproc`/`:normal` clause, so it
propagates.

This is not test-only. Any production run whose command fails fast enough races the
same window in whatever process called `spawn_run/2`.

**Measured reproduction rate.**

| condition | result |
|---|---|
| file alone, seeds 1–20, uncontended | **0 / 20** |
| inside the full suite (uncontended) | **1 / 2** (§26's probe run red, the gate run green) |
| mechanism control: `Process.sleep(50)` inserted between `start_link` and `provider_ref/1` | **1 / 1, deterministic** |

The control, since 0/20 in isolation is not evidence of absence:

```
$ # local_runner.ex:54, with `Process.sleep(50)` inserted immediately above
$ PLATFORM_TEST_DATABASE=platform_test_019fb978 mix test \
    test/platform/execution/local_runner_test.exs --seed 1

  1) test LocalRunner stop/kill force_stop after wrapper exit is safe (idempotent)
     ** (exit) exited in: GenServer.call(#PID<0.578.0>, :provider_ref, 5000)
         ** (EXIT) no process: the process is not alive …
       (platform 0.1.0) lib/platform/execution/local_runner.ex:55: …spawn_run/2
18 tests, 1 failure
```

Same test, same call site, same argument; only the width of the window changed. The
exit reason differs (`no process` vs `normal`) purely by whether the name had already
been released when the call was issued — both are the same race. Mutation reverted;
`git status --short` clean.

**NOT FIXED HERE.** `lib/platform/execution/local_runner.ex` is not in this stage's
grant, the fix is a production behaviour change on the execution plane (`spawn_run/2`
must tolerate a wrapper that has already completed — most likely by having
`LocalProcessWrapper` return its `provider_ref` from `start_link/1` rather than
requiring a second round trip), and it deserves its own controls. **Its own ticket.**
It is also the most likely candidate for a future "`test/platform/execution/` is
flaky again" report, which is the reason it is written down here rather than
mentioned in a commit message.

## 38. Summary of the sweep

* **21 rows, all filled.** 15 CLEAN, 1 CLEAN-by-unreachability with the reachability
  conditions named (#6), 1 real-but-unreached mechanism (#21), 1 DEFECTIVE (#17),
  3 clean-by-non-participation (#9, #15, #16).
* **Two planner pre-verdicts confirmed** (`MeetingNotifier`, `RuntimePresence`),
  **one confirmed with an addition** (`AttentionRouter` — its `data_case.ex` entry is
  dead, and so is `Responsibilities.Router`'s), **one FALSIFIED**
  (`DeadLetterReplay`: 6 measured violations; `safely/1` does not prevent them).
* **Three findings the stage description did not name:** a second `:named_table,
  :public` singleton table (`:suite_context_plane`, §32); `Responsibilities.Router`
  as a stronger start-gating precedent than `MeetingNotifier` (§33); and a production
  race in `LocalRunner.spawn_run/2` reproduced deterministically under a 50 ms
  control (§37).
* **One correction to this note's own §11** (§36.3): the cited line is a Postgres
  read, not an ETS read, and the ETS mechanism it blames was measured at zero
  restarts across a full run.
* **Zero hunks in `lib/` and `test/`.** Every defect found sits outside this stage's
  file grant, each is named with its fix design and its owner, and none is absorbed
  silently.
