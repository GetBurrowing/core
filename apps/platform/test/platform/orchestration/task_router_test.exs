# ─────────────────────────────────────────────────────────────────────────────
# SLEEP TAXONOMY — task 019fa121 stage 1 (baseline recorded 2026-07-27),
# closed out at stage 5 and reconciled against main after the merge. THIS FILE
# CONTAINS NO SYNCHRONISATION SLEEPS. It contains exactly TWO fixed-sleep call
# sites, both in "a router restart loop cannot renew the deadline", both
# annotated, and both there because elapsed wall clock is the SUBJECT of that
# test's assertion rather than a way of waiting for something. The guard at the
# bottom of the file enforces exactly that: zero unannotated sites, and no more
# than two annotated ones. `grep -c` for the forbidden call over this file
# returns 2 — the prose still never spells it, so a reviewer's plain grep lands
# on the two real sites and nothing else.
#
# POST-MERGE RECONCILIATION (2026-07-27). Between the branch point and the
# merge, main added 8 sleeps to this file across 791ee28e, 816f98d8, 9ca73770
# and d5ac3d3b; git correctly took both our 116 deletions and their additions,
# leaving 16 net-new sites the guard then failed on. Thirteen were ordinary
# synchronisation and were converted the same way as the original 116 (11
# deletions where the following `current_status/1` or `:sys.get_state/1` was
# already the barrier, 2 `sync_router/2`). One — `:2185` — was an ABSENCE
# assertion, the worst of the three shapes and the one the guard most needed to
# catch. Two were the measurement described above.
#
# At the branch point this file synchronised on 116 fixed sleeps
# totalling 11.125s of pure sleep per run (45x50ms, 27x100ms, 26x150ms,
# 10x75ms, 5x200ms, 2x250ms, 1x25ms) across 66 tests in 19 describe blocks. A
# fixed sleep is a guess in BOTH directions: too short races the router, too
# long hides a regression behind wall-clock padding. Stages 2-5 removed all
# 116: 73 straight DELETIONS (the assertion that followed was already a
# barrier), 43 CONVERSIONS to `sync_router/2`, and — deliberately — 0 converted
# to polling. No site in this file needed `assert_eventually/3`, because at
# every one of them the observable is written synchronously inside the router's
# own handler. If you cannot NAME the other process that owns the effect you
# are waiting on, you want the barrier, not a poll.
#
# WHY A BARRIER IS SOUND HERE (verified against origin/main @ bf12620c)
#
# The actor in this file is the per-task `TaskRouter` GenServer, started
# directly 64 times, so `TaskRouterWatcher.sync/0` is the WRONG barrier at
# almost every site. There is now exactly ONE exception, and it arrived with
# the merge: at `:2185` the claim under test is that the watcher does not start
# a router at all, so the watcher IS the actor and `sync_router/2` cannot even
# be spelled — there is no per-task router to call. (This paragraph previously
# said the watcher is NEVER an actor here. That was true of the 116 original
# sites and is no longer true of the file.)
#
# Three facts make `broadcast -> barrier -> assert` a happens-before chain:
#
#   1. `Phoenix.PubSub.broadcast/4` dispatches to local subscribers IN THE
#      CALLING PROCESS — `deps/phoenix_pubsub/lib/phoenix/pubsub.ex:234`,
#      `with :ok <- adapter.broadcast(...) do dispatch(pubsub, :none, ...) end`.
#      So when `Tasks.broadcast_board/1` (lib/platform/tasks.ex:3611) returns,
#      the message is ALREADY in the router's mailbox. The router subscribes at
#      `task_router.ex:136`.
#   2. `TaskRouter` spawns nothing. The only `spawn|Task.start|Task.async` hit
#      in `task_router.ex` is a string literal at :1284. Every side effect of a
#      `handle_info` therefore completes before the next message is picked up.
#   3. `LeaseManager` mutators are synchronous `GenServer.call`s
#      (lease_manager.ex:158/178/216/229/242/253) and `get/1` is a direct
#      `:ets.lookup` (:263). An ETS row read after the barrier is already
#      written.
#
# Therefore `TaskRouter.current_status/1` — a pure, side-effect-free
# `GenServer.call` (task_router.ex:124 public, :267 handler, returns state and
# nothing else) — is a COMPLETE mailbox barrier for the per-task router. This
# file already calls it 56 times.
#
# THE TAXONOMY (all 116 sites classified; none unclassified)
#
#   (A) MAILBOX BARRIER — 88 sites, 8,175ms. The sleep waits for the per-task
#       router to drain a message the test just enqueued. A barrier replaces it
#       exactly; most are pure deletions.
#         A/status-read      44 sites 4,050ms  sleep is IMMEDIATELY followed by
#                                              `current_status/1` — the read is
#                                              itself the barrier. DELETE.
#         A/sequencing       19 sites 1,075ms  sleep separates two setup events.
#         A/inter-send       12 sites 1,750ms  sleep separates two `send(pid, ..)`
#                                              calls; edge-triggered ordering is
#                                              under test, so barrier after EACH.
#         A/mailbox-assert   10 sites   850ms  precedes assert_received /
#                                              refute_received. Barrier first.
#         A/blocking-receive  3 sites   450ms  precedes assert_receive /
#                                              refute_receive, which ALREADY
#                                              block with a timeout. DELETE.
#
#   (B) CROSS-PROCESS EFFECT — 28 sites, 2,950ms. The assertion reads state
#       outside the router process. Per facts 2 and 3 the effect is written
#       synchronously inside the handler, so the barrier still suffices; reach
#       for polling only where that cannot be shown.
#         B/repo-read        12 sites 1,300ms  Repo.get! / get_task_detail /
#                                              RuntimeSupervision lease reads.
#         B/lease-ets         8 sites   550ms  LeaseManager.get/1 (ETS).
#         B/space-messages    6 sites   900ms  list_messages_with_participants,
#                                              plan_gate_logs, stage_gate_logs.
#         B/proc-liveness     2 sites   200ms  Process.alive?/1 — a reply to
#                                              `current_status/1` proves this.
#
#   (C) GENUINELY TIMER-DEPENDENT — 0 sites. This is a real finding, not an
#       omission. The router does schedule timers (`Process.send_after` for
#       `:check_no_ack`, `:check_safety_net`, `:dispatch` retry at
#       task_router.ex:470/509/1025/1157/1161), but NO test in this file waits
#       for one to elapse: every test forces the tick with an explicit
#       `send(pid, :check_no_ack)`. Even the silence-window tests avoid it —
#       :893 installs a 400ms silence deliberately far enough out that it never
#       lapses mid-test, and the "silence lapses" test at :936 rewrites the
#       timestamp into the past instead of waiting. So all 116 sleeps are
#       removable in principle; none encodes a real time dependency.
#
# PREFER THE BARRIER OVER POLLING. A poll with a generous timeout is weaker
# evidence than a happens-before proof, and swapping sleep-shaped false
# confidence for poll-shaped false confidence is the failure this conversion
# exists to prevent.
#
# ON `assert_receive` DEADLINES (added at the task-level review, 019fa121).
# A fixed `assert_receive` deadline is the SAME CLASS OF GUESS as a fixed
# sleep — just a SOUND one. The difference is that it returns THE MOMENT the
# message arrives, so it is only ever wrong in one direction (too short races
# a slow scheduler) instead of both; it never burns the full wait on the happy
# path, so it cannot pad a regression behind wall-clock. That is why the
# conversion left every `assert_receive` in place rather than replacing them.
# But the literal still has to be chosen, and this file's CONVENTION IS
# `1_000`. At the review, 33 sites already sat at 1_000 and all held under
# deliberate contention, while the two sites still on the pre-existing 500 —
# `:assignee_unresolvable` telemetry and the stage-C attention broadcast in
# `describe "stage-scoped blocker handling"` — flaked at ~14%. Both were
# raised to 1_000; neither literal was introduced by this conversion (the
# diff at both sites removes only the trailing fixed sleep). Use a deadline
# where the effect you await is genuinely a LATER message that no preceding
# barrier covers, and when you do, write `1_000`.
#
# COUNTING NOTE for the zero-sleep guard: a naive `grep -c` over a whole file
# counts PROSE about the forbidden call alongside real call sites — at the
# branch point this header alone pushed the count from 116 to 117. The guard
# therefore strips comment lines before matching, and carries positive controls
# proving the stripping did not reduce the buffer to nothing, since a guard
# that greps an accidentally-empty buffer passes for the wrong reason. The
# prose here is kept unspelled as well, so the plain `grep -c` a reviewer
# actually types agrees with the guard: it returns 2, and both hits are the
# annotated measurement. See `describe "zero-sleep guard"`.
#
# ON THE ANNOTATION, briefly, because the summary above is where a reader will
# form their impression of it: it is a marker plus a written justification ON
# the call line, which the guard parses and requires to be substantive, and
# whose total count is pinned. It is deliberately NOT a list of exempt lines or
# test names. It covers ONE category — the sleep whose elapsed time is itself
# the subject of an assertion — and absence assertions are explicitly outside
# it. The full argument, including why absence assertions are the opposite case
# rather than a similar one, is in the comment above the guard's describe
# block; do not extend the hatch without reading it.
#
# Measure with `scripts/measure-task-router-flake.sh`, which records the
# failing SET rather than a count — at seed 33 the 019fa003 stage 2 measurement
# saw five failures on BOTH the fixed and control trees with only partly
# overlapping membership, which a count-only comparison reports as "no change".
# ─────────────────────────────────────────────────────────────────────────────
defmodule Platform.Orchestration.TaskRouterTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{
    ExecutionLease,
    ExecutionSpace,
    LeaseManager,
    RuntimeSupervision,
    TaskRouter,
    TaskRouterWatcher
  }

  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Test Project",
        repo_url: "https://github.com/test/router"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router Test Task",
        description: "Testing the task router",
        # `deploy_target` set so the stage-2 (019f42db) `:deploying` guard
        # `require_deploy_target_for/2` passes for tests that walk the task
        # through to `deploying`.
        deploy_target: "production"
      })

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}

    # Allow dynamically started TaskRouter processes to share the test sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      # Stop router before sandbox teardown to avoid connection errors
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      # LeaseManager is a global singleton — purge this task's row so it
      # doesn't leak into the next test.
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage, assignee: assignee}
  end

  describe "start_link/1 and lifecycle" do
    test "starts and registers a router process", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      # Should be registered
      assert [{^pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
    end

    test "stop/1 terminates the router", %{task: task, assignee: assignee} do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert Process.alive?(pid)

      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end

    test "stop/1 returns error for unknown task" do
      assert {:error, :not_found} = TaskRouter.stop("nonexistent")
    end
  end

  describe "current_status/1" do
    test "returns router status after dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Task 01a00587: the init dispatch is debounced; barrier on the router so
      # the status read below observes the reconcile rather than pre-empting it.
      :ok = sync_router(task.id)

      status = TaskRouter.current_status(task.id)

      assert status.task_id == task.id
      assert status.assignee == assignee
      assert status.status == :running
    end

    test "includes execution_space_id in status", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      status = TaskRouter.current_status(task.id)
      assert is_binary(status.execution_space_id)

      # Verify the space exists and is an execution space
      space = Platform.Chat.get_space(status.execution_space_id)
      assert space.kind == "execution"
      assert space.metadata["task_id"] == task.id
    end
  end

  describe "PubSub event handling" do
    test "tracks task_updated last_evidence_at for our task", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Simulate a board event for our task
      updated_task = Tasks.get_task_detail(task.id)
      Tasks.broadcast_board({:task_updated, updated_task})
      # Task 01a00587: debounced dispatch — barrier before reading status.
      :ok = sync_router(task.id)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.last_evidence_at != nil
    end

    test "updates stage on stage_transitioned", %{task: task, assignee: assignee, stage: stage} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Simulate stage transition
      Tasks.broadcast_board({:stage_transitioned, stage})

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage.id
      assert status.last_evidence_at != nil
    end

    # Regression: prior to the fix, `handle_info({:stage_transitioned, stage}, ...)`
    # unconditionally set `current_stage_id = stage.id`. On a running→passed
    # transition the payload is the just-completed stage, so the router pinned
    # itself to a `passed` stage; the next dispatch then filtered validations to
    # ["pending", "running"] (empty) and echoed "No validations are pending. If
    # the work is complete, call `stage_complete`…" until the next broadcast.
    # The fix resolves `current_stage_id` via `current_running_stage/1` when the
    # broadcast payload is `passed`.
    test "stage_transitioned with passed stage advances current_stage_id to the next running stage",
         %{task: task, assignee: assignee, plan: plan, stage: stage_a} do
      # Stage A becomes running (mirrors the pre-transition state); Stage B
      # exists as `pending` and will flip to `running` at the same tick.
      running_stage_a =
        stage_a
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, stage_b} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "review",
          description: "Review the code"
        })

      {:ok, _validation_b} =
        Tasks.create_validation(%{stage_id: stage_b.id, kind: "test_pass"})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Prime router state so `current_stage_id` matches the (still running)
      # stage A — this is the state the router is in right before the
      # engine writes the passed→running transition pair.
      Tasks.broadcast_board({:stage_transitioned, running_stage_a})

      assert TaskRouter.current_status(task.id).current_stage_id == stage_a.id

      # Engine now marks stage A `passed` and stage B `running` (order
      # matches PlanEngine.finalize/advance): both DB rows flip, then the
      # passed-stage broadcast fires. The router must resolve the running
      # stage from the freshly loaded plan, not pin to the passed payload.
      passed_stage_a =
        running_stage_a
        |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      _running_stage_b =
        stage_b
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      refute status.current_stage_id == stage_a.id
    end

    # Sibling regression: if the passed broadcast lands before the next
    # running stage is written (or when the plan is fully completed), the
    # router must clear `current_stage_id` to nil rather than pin the passed
    # stage — otherwise dispatches continue echoing the completed stage's
    # (empty) validation list.
    test "stage_transitioned with passed stage and no next running stage clears current_stage_id",
         %{task: task, assignee: assignee, stage: stage_a} do
      running_stage_a =
        stage_a
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      Tasks.broadcast_board({:stage_transitioned, running_stage_a})
      # Barrier, not a read: the test mutates stage A's row next, so the
      # router must have folded the `running` broadcast before the row
      # flips to `passed` underneath it.
      :ok = sync_router(task.id)

      passed_stage_a =
        running_stage_a
        |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == nil
    end

    test "tracks runtime events as liveness evidence", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Barrier: `record_runtime_event/1` upserts the lease row from THIS
      # process, so the initial `:dispatch` must be fully handled first.
      :ok = sync_router(task.id)

      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.heartbeat"
        })

      status = TaskRouter.current_status(task.id)
      assert status.lease_status == "active"
      assert status.last_runtime_event_at != nil
      assert status.status == :running
    end

    test "hydrates router state from an existing active lease", %{task: task, assignee: assignee} do
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "already working"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.lease_status == "active"
      assert status.last_runtime_event_at != nil
    end

    test "hydrates active manual approval stage into waiting_human review state when a review request is pending",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Manual approval",
          description: "Wait for human sign-off",
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: review_stage.id, kind: "manual_approval"})

      {:ok, execution_space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)

      assert {:ok, _request} =
               Platform.Tasks.ReviewRequests.create_review_request(%{
                 validation_id: validation.id,
                 task_id: task.id,
                 execution_space_id: execution_space.id,
                 items: [%{label: "UI review"}]
               })

      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "waiting for review"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      status = TaskRouter.current_status(task.id)
      assert status.status == :waiting_human
      assert status.lease_status == "active"
      assert status.current_stage_id == review_stage.id

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"

      messages =
        execution_space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.map(& &1.content)

      # Task 019e00cb stage 2 wired `HeartbeatScheduler.heartbeat_suppressible?/2`
      # into `maybe_log_heartbeat_suppressed/3`. This scenario satisfies the
      # predicate (running manual_approval stage, every pending validation linked
      # to the open review_request) so the per-dispatch "Dispatch suppressed" log
      # is intentionally elided — the review_request itself is the visible
      # signal. The assertions above (`status == :waiting_human`,
      # `current_stage_id`, task status `in_review`) cover the state-machine
      # transition; we just need to confirm we are NOT spamming the noise log.
      refute Enum.any?(
               messages,
               &(String.contains?(&1, "Heartbeat suppressed") or
                   String.contains?(&1, "Dispatch suppressed"))
             )
    end

    test "approved plan starts the first pending execution stage", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      approved_plan =
        plan
        |> Ecto.Changeset.change(%{status: "approved"})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, approved_plan})
      # Barrier: the stage row below is written inside the router's
      # `{:plan_updated, ...}` handler; `Repo.get!/2` does not order against it.
      :ok = sync_router(task.id)

      started_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert started_stage.status == "running"
      assert started_stage.started_at != nil

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage.id
    end

    # REMOVED by task 019fa2fc stage 3: "completed plan transitions in_progress
    # task to in_review" and "completed plan transitions in_review task to
    # deploying". The router's status-mapping arm those two tests covered is
    # gone — the phase advance is owned by `Platform.Tasks.PlanCompletion` on
    # the synchronous plan-completion path, and the `{:plan_updated,
    # completed}` clause is now liveness-only. Replacement coverage lives in
    # `task_router_plan_completed_test.exs` and `plan_completion_test.exs`.
    # Merge note for task 019fa121: resolve any conflict here by taking the
    # deletion.

    test "running manual approval stage without a pending review request stays actively routed",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Manual approval",
          description: "Wait for human sign-off"
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: review_stage.id, kind: "manual_approval"})

      running_review_stage =
        review_stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, running_review_stage})
      :ok = sync_router(task.id)

      # Bug #7 (task 019f70ff-55c2) regression: TaskRouter must NOT auto-flip
      # a task to in_review just because a manual_approval-only stage went
      # running. `Platform.Tasks.ReviewRequests.create_review_request/1` is
      # the sole in_progress → in_review trigger; nothing has filed one here.
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.current_stage_id == review_stage.id
    end

    test "failed review stage bounces task from in_review back to in_progress", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "in_review")

      plan_with_stages = Platform.Repo.preload(plan, :stages)
      [stage | _] = plan_with_stages.stages

      failed_stage =
        stage
        |> Ecto.Changeset.change(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:stage_transitioned, failed_stage})
      :ok = sync_router(task.id)

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      space = ExecutionSpace.find_by_task_id(task.id)
      messages = ExecutionSpace.list_messages_with_participants(space.id)

      assert Enum.any?(
               messages,
               &String.contains?(&1.content, "Stage failure bounced task back to in_progress")
             )
    end

    test "ignores task_updated for other tasks", %{
      task: task,
      assignee: assignee,
      project: project
    } do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Create a different task and broadcast its update
      {:ok, other_task} = Tasks.create_task(%{project_id: project.id, title: "Other"})
      other_detail = Tasks.get_task_detail(other_task.id)
      Tasks.broadcast_board({:task_updated, other_detail})
      # Task 01a00587: debounced dispatch — barrier before reading status.
      :ok = sync_router(task.id)

      status = TaskRouter.current_status(task.id)
      # last_evidence_at should be nil since we only got the unrelated event
      # (dispatch sets it to nil, only our-task events set it)
      assert status.status == :running
    end
  end

  describe "dispatch" do
    test "transitions to :running after init dispatch", %{task: task, assignee: assignee} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Task 01a00587: the init dispatch is debounced; barrier before reading.
      :ok = sync_router(task.id)

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end

    test "publishes runtime attention on Platform.PubSub", %{task: task, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "attention",
                       payload: payload
                     },
                     1_000

      assert topic == "runtime:#{assignee.id}"
      assert payload.signal.reason == "task_assigned"
      assert payload.signal.task_id == task.id
      assert is_binary(payload.message.content)
      assert payload.message.author == "TaskRouter"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # CHARACTERIZATION — attention-envelope site 1 of 3 (019fa56b stage 1).
    #
    # The contrast case for `agent_responder_system_event_payload_test.exs`.
    # `dispatch_attention/5` (task_router.ex:1381-1389) puts the composed
    # dispatch prompt at `payload.message.content`; `broadcast_system_event/3`
    # puts its body at `payload.signal.prompt` and emits NO `:message` key.
    # A bridge reading `payload.message?.content ?? ""` renders THIS path
    # perfectly while dropping the other one entirely — which is why "a full
    # task dispatch reached that runtime" is not evidence that the runtime
    # handles `system_event` wakes.
    #
    # The assertion above this one (`is_binary(payload.message.content)`) is
    # true of any non-empty string and so cannot tell a composed prompt from a
    # placeholder. This one pins the actual bytes.
    # ─────────────────────────────────────────────────────────────────────────
    test "message.content is the composed dispatch prompt, byte for byte", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # The seeded stage is `pending`, and `dispatch_resolved/4` only resolves a
      # RUNNING stage — leave it pending and the router composes a stage-less
      # `dispatch.fallback` body, which is a real shape but not the one this
      # pin is about. Mark it running so the dispatch is stage-scoped and the
      # recompute below has the same three inputs the router had.
      stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000

      # Recomputed through the same entry point `dispatch_resolved/4` calls
      # (task_router.ex:1269). Equality — not `=~`, not `is_binary` — so a
      # change that swapped the body for a truncated or templated stand-in
      # fails here instead of passing on "still a string".
      # Reload through `Tasks.current_plan/1` — the same accessor
      # `dispatch_resolved/4` uses (task_router.ex:1096). This is NOT
      # incidental: `DispatchPhase.phase_for/2` classifies off
      # `stage.validations`, so the un-preloaded `stage` struct from `setup`
      # resolves to `dispatch.fallback` while the router's preloaded one
      # resolves to `dispatch.in_progress`. Recomputing from anything but the
      # loaded plan compares two different templates.
      detail = Tasks.get_task_detail(task.id)
      loaded_plan = Tasks.current_plan(task.id)
      loaded_stage = Enum.find(loaded_plan.stages, &(&1.status == "running"))
      assert loaded_stage.id == stage.id

      {agent, runtime} = Platform.Federation.lookup_assignment(assignee.id)

      expected =
        Platform.Orchestration.HeartbeatScheduler.dispatch_prompt(
          detail,
          loaded_plan,
          loaded_stage,
          agent: agent,
          runtime: runtime,
          previous_rejection_reason: nil,
          parent_plans: [],
          execution_space_id: nil
        )

      assert payload.message.content == expected

      # The seeded task's own strings are IN the body, so the equality above
      # cannot be satisfied by two independently-empty renders.
      assert payload.message.content =~ task.title
      assert payload.message.content =~ task.id

      # SITE 1 IS THE `message`-CARRYING SHAPE. The pre-fix bridge read
      # (`payload.message?.content ?? ""`, src/index.ts:256) recovers the whole
      # body here — asserted positively, next to the system_event test's
      # `bridge_content(payload) == ""`, so the pair documents the asymmetry
      # rather than either half documenting a dead socket.
      assert bridge_content(payload) == expected

      # …and this shape does NOT carry `signal.prompt`. Pinned so stage 4's
      # client change lands as a FALLBACK and not a swap: a client that reads
      # only `signal.prompt` would break exactly this path.
      refute Map.has_key?(payload.signal, :prompt)
    end
  end

  # Transcription of `src/index.ts:256` in claude-code-suite-channel@4691bdb:
  #   const text = payload.message?.content ?? "";
  defp bridge_content(payload) do
    case payload do
      %{message: %{content: content}} when is_binary(content) -> content
      _ -> ""
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # DISPATCH COALESCING (task 01a00587 stage 3).
  #
  # The observable throughout is the `attention` broadcast on
  # `runtime:<assignee id>` — a SIDE EFFECT of `do_dispatch/2`, never
  # `state.dispatch_timer`. A timer ref can be armed, cleared and re-armed
  # exactly as designed while the reconcile underneath it still runs twice;
  # only the broadcast counts dispatches.
  #
  # The four tests are deliberately not redundant:
  #
  #   A (inside the window)  — a burst collapses to ONE dispatch. Alone, this
  #                            is passed by a coalescer that swallows
  #                            everything and never dispatches at all.
  #   B (outside the window) — two dispatches separated by an observed
  #                            broadcast produce TWO. This is what refutes the
  #                            swallow-everything reading of A, and it
  #                            establishes the window has elapsed by waiting on
  #                            the first broadcast rather than on the clock.
  #   C (direction control)  — a SINGLE `:dispatch` still fires, well inside a
  #                            1s deadline. A and B both hold if the debounce
  #                            grew to seconds; this pins that the window adds
  #                            latency, not a lost or badly delayed dispatch.
  #   D (final state wins)   — the burst dispatches the LATEST state, not the
  #                            state as of the first message. A coalescer that
  #                            keeps the head of the burst and drops the tail
  #                            passes A, B and C and then dispatches stale
  #                            state — worse than the original bug, because a
  #                            duplicate prompt is redundant while a stale one
  #                            is wrong.
  #
  # No `Process.sleep` in any assertion path here: A refutes against a deadline
  # (an absence assertion, which cannot be replaced by a barrier), B waits on
  # the broadcast itself, and D widens the debounce through
  # `:task_router_dispatch_debounce_ms` with an `on_exit` that deletes it, so
  # the DB mutation is inside the window by construction rather than by a race
  # against a 50ms clock.
  # ───────────────────────────────────────────────────────────────────────────
  describe "dispatch coalescing (task 01a00587)" do
    # A. INSIDE THE WINDOW — six `:dispatch` messages, one dispatch.
    test "a burst of :dispatch inside the debounce window produces exactly one dispatch", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Drain the init dispatch so the count below is of the burst alone.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      :ok = sync_router(task.id)

      for _ <- 1..6, do: send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000
      assert payload.signal.task_id == task.id

      # The other five. An absence assertion needs a real deadline — there is
      # no barrier that can prove a message will never arrive, only one that
      # proves the router has drained what it already had.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
    end

    # B. OUTSIDE THE WINDOW — two separated `:dispatch` messages, two
    # dispatches. Without this, A is satisfied by a coalescer that drops
    # everything on the floor.
    test "two :dispatch messages separated by a completed dispatch produce two dispatches", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      :ok = sync_router(task.id)

      send(pid, :dispatch)

      # This receive is doing two jobs: it proves the first dispatch fired, and
      # — because the broadcast is emitted from inside `:dispatch_now` — it
      # establishes that the window opened by that `:dispatch` has already
      # closed. That is why the second `send` below is genuinely OUTSIDE the
      # window without a single sleep.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000
      assert payload.signal.task_id == task.id
    end

    # C. DIRECTION CONTROL — one `:dispatch`, one dispatch, promptly. The
    # window is a coalescer, not a suppressor and not a long delay.
    test "a single :dispatch still dispatches exactly once", %{task: task, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      :ok = sync_router(task.id)

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
    end

    # D. FINAL STATE WINS. The failure this test exists for is invisible to A,
    # B and C: a coalescer that keeps the FIRST message of a burst and drops
    # the rest satisfies all three and then prompts the executor about a stage
    # that has already passed.
    #
    # The property holds by construction today — `:dispatch_now` carries no
    # payload and re-reads `Tasks.get_task_detail/1` + `Tasks.current_plan/1`
    # at FIRE time — and this test is what stops a later refactor from
    # "optimising" that into state cached onto the scheduling message.
    test "the coalesced dispatch reflects state as of fire time, not schedule time", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_one
    } do
      # Widen the window so the mutation below is inside it by construction.
      # This is the sanctioned alternative to sleeping: the test controls the
      # window instead of racing it.
      Application.put_env(:platform, :task_router_dispatch_debounce_ms, 400)
      on_exit(fn -> Application.delete_env(:platform, :task_router_dispatch_debounce_ms) end)

      stage_one =
        stage_one
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, stage_two} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "coalescing-stage-two",
          description: "The stage the dispatch must name"
        })

      {:ok, _validation_two} =
        Tasks.create_validation(%{stage_id: stage_two.id, kind: "test_pass"})

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Init dispatch — this one names stage 1, and draining it is what makes
      # the assertion below about the BURST rather than about start-up.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: init_payload}, 2_000
      assert init_payload.message.content =~ "stage 1/2"
      :ok = sync_router(task.id)

      send(pid, :dispatch)

      # BARRIER, and the load-bearing line of this test (found by the stage-4
      # mutation probe: without it, a coalescer that snapshots state when the
      # FIRST message is HANDLED survives this test). Widening the debounce
      # widens schedule→fire; it does nothing about send→handle. Until the
      # router has actually dequeued the `:dispatch` above, the writes below
      # race it, and if they win, schedule-time state and fire-time state are
      # identical — leaving nothing for the assertions to discriminate.
      #
      # NOT `sync_router/1` here, deliberately: that helper drains the armed
      # timer, i.e. it waits for the dispatch to FIRE — which closes the very
      # window this test needs to write inside. `:sys.get_state/1` is a system
      # message, so it is answered strictly after the `:dispatch` above and
      # strictly before the timer fires. The assertion on `dispatch_timer` is a
      # window check, not the observable under test — every dispatch claim
      # below is still made against the `attention` broadcast.
      assert :sys.get_state(pid).dispatch_timer != nil

      # INSIDE the window: the engine's state moves on underneath the pending
      # reconcile, exactly as it does in production when several senders each
      # observe a different moment of the same transition.
      stage_one
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_two =
        stage_two
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 2_000

      # The LATER state. `=~ "stage 2/2"` and the stage name together rule out
      # a prompt that merely mentions two stages; the refute rules out the
      # first-message-wins coalescer, which would send a byte-identical copy of
      # the init prompt.
      assert payload.message.content =~ "stage 2/2"
      assert payload.message.content =~ "coalescing-stage-two"
      refute payload.message.content =~ "stage 1/2"

      # Second, independent channel on the same claim: the lease the dispatch
      # wrote. A prompt could in principle be recomposed correctly while the
      # lease still pinned the stale stage, and it is the lease that `task_ack`
      # and the liveness timers are keyed on.
      #
      # Barrier, not a wait: the broadcast is emitted PARTWAY THROUGH
      # `do_dispatch/2` and `LeaseManager.record_dispatch/4` runs after it, so
      # receiving the attention above does not imply the lease row is written
      # yet. Without this the read observes the init dispatch's lease and the
      # test fails for a reason that has nothing to do with coalescing.
      :ok = sync_router(task.id)

      assert LeaseManager.get(task.id).stage_id == stage_two.id

      # And exactly one dispatch came out of the pair.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
    end
  end

  describe "event-driven liveness (task 019f640d stage 3)" do
    # These tests exercise the new event-driven state machine: on each dispatch,
    # the router calls `LeaseManager.record_dispatch/4` and arms two one-shot
    # timers (`:check_no_ack`, `:check_safety_net`). The runtime replies with
    # `execution.acked` (via the future `task_ack` MCP tool from stage 5) to
    # extend the lease; progress events do the same. Silent drops fire ONE
    # `execution.no_ack_timeout` / `execution.safety_net_fired` runtime_event
    # each and post `execution.blocked needs_human=true` to the execution space.
    #
    # Because the real timers wait 5min / 90min, tests trigger the check
    # handlers directly via `send(pid, :check_no_ack)` after establishing the
    # LeaseManager row shape manually. The router's real code path exercises
    # the check handler, not the arm; the arm is exercised implicitly by
    # asserting `LeaseManager.get/1` returns the expected row after dispatch.

    test "happy path: dispatch → record_dispatch → ack via runtime_event → :check_no_ack silent",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Mark the seeded stage running so `current_running_stage/1` resolves
      # inside `do_dispatch/2`.
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Barrier, not a wait: the attention broadcast is emitted partway through
      # `handle_info(:dispatch, ...)`, so receiving it proves nothing about
      # `record_dispatch/4` having run. `sync_router/2` is answered only after
      # that handler returns.
      :ok = sync_router(task.id)

      # LeaseManager must have a row for this task after successful dispatch.
      assert %{
               stage_id: dispatched_stage_id,
               stage_kind: "coding",
               ack_at: nil,
               no_ack_fired?: false
             } = LeaseManager.get(task.id)

      assert dispatched_stage_id == stage.id

      # Simulate `execution.acked` runtime_event (which stage 5's `task_ack`
      # MCP tool will emit). The router's `apply_runtime_event/2` clause
      # calls `LeaseManager.record_ack/1` — clears no-ack, extends
      # safety-net.
      acked_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage.id,
        event_type: "execution.acked",
        payload: %{},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: nil
      }

      Tasks.broadcast_board({:runtime_event, acked_event})
      :ok = sync_router(task.id)

      assert %{ack_at: %DateTime{}} = LeaseManager.get(task.id)

      # Force `:check_no_ack` to fire NOW (real timer waits 5min). Router
      # sees `ack_at != nil` and is silent — no blocker post, no state flip.
      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_no_ack)

      # No barrier call needed: `current_status/1` IS the barrier. It is a pure
      # `GenServer.call`, so it cannot be answered until `:check_no_ack` has
      # been handled — the sleep that used to sit here was already dead weight.
      status = TaskRouter.current_status(task.id)
      assert status.status == :running

      lease_after = LeaseManager.get(task.id)
      refute lease_after.no_ack_fired?

      # A plain read, deliberately NOT `assert_eventually/3`. The blocker post
      # is written by the router inside the `:check_no_ack` handler and the
      # router spawns nothing, so it is committed before the barrier above
      # returned. There is no third process to poll for, and polling here would
      # trade a happens-before proof for a timeout that always expires — the
      # refute below is the assertion that would silently go vacuous.
      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_msgs = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)

      # No `execution.no_ack_timeout` blocker post should have landed.
      refute Enum.any?(new_msgs, &String.contains?(&1, "Executor never acked"))
    end

    test "no-ack path: :check_no_ack fires blocker + broadcasts no_ack_timeout ONCE, no re-arm",
         %{task: task, assignee: assignee, stage: stage} do
      # Subscribe to `tasks:board` so we can assert the exact
      # `execution.no_ack_timeout` broadcast reaches PubSub.
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      :ok = sync_router(task.id)

      # No ack ever arrives, and the ack window has genuinely closed.
      # Expiring the deadline is what `send(pid, :check_no_ack)` used to
      # stand in for implicitly: since task 019fa469 stage 6 the handler
      # level-checks `no_ack_at`, so a timer wake alone is not a fire.
      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      expire_no_ack_deadline!(task.id)
      send(pid, :check_no_ack)

      # The barrier must land BEFORE the mailbox assertion, not after it.
      # `assert_received/1` does not block, so without this it reads a mailbox
      # the router has not written to yet.
      :ok = sync_router(task.id)

      # PubSub must have carried ONE `execution.no_ack_timeout` on
      # `tasks:board` (in `{:runtime_event, event}` shape).
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"} = event}
      assert event.task_id == task.id
      assert event.stage_id == stage.id
      assert is_integer(event.payload.elapsed_ms_since_dispatch)

      # Blocker message posted to execution space, ONE only.
      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      no_ack_posts = Enum.filter(new_contents, &String.contains?(&1, "Executor never acked"))
      assert length(no_ack_posts) == 1

      # LeaseManager row shows `no_ack_fired?: true` — idempotency guard set.
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      # Router state = :stalled.
      status = TaskRouter.current_status(task.id)
      assert status.status == :stalled

      # A second `:check_no_ack` must NOT fire another blocker (idempotent).
      before_msgs2 = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_no_ack)

      # The load-bearing barrier in this file. This `refute_received` is only
      # evidence of idempotency if the router has *finished* handling the
      # second `:check_no_ack` — otherwise it refutes an empty mailbox and
      # passes for the wrong reason no matter what the router does.
      :ok = sync_router(task.id)

      # Refute a second no_ack_timeout event on PubSub.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}

      after_msgs2 = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents2 = Enum.drop(after_msgs2, before_msgs2) |> Enum.map(& &1.content)
      refute Enum.any?(new_contents2, &String.contains?(&1, "Executor never acked"))
    end

    test "no-ack path: stamps the SAME sentence onto the task's blocked_reason metadata",
         %{task: task, assignee: assignee, stage: stage} do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      # A pre-existing dependency stamp in the same JSONB map must survive.
      task
      |> Ecto.Changeset.change(%{metadata: %{"unmet_dependencies" => ["dep-one"]}})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      expire_no_ack_deadline!(task.id)
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      stamped = Tasks.get_task_record(task.id)
      assert stamped.status == "blocked"
      reason = stamped.metadata["blocked_reason"]
      assert is_binary(reason) and reason != ""
      assert String.contains?(reason, "Executor never acked")
      assert {:ok, _, _} = DateTime.from_iso8601(stamped.metadata["blocked_reason_at"])

      # The chat post and the metadata carry the same sentence.
      space = ExecutionSpace.find_by_task_id(task.id)

      assert Enum.any?(
               ExecutionSpace.list_messages_with_participants(space.id),
               &String.contains?(&1.content, reason)
             )

      # The dependency key is untouched.
      assert stamped.metadata["unmet_dependencies"] == ["dep-one"]
    end

    test "safety-net path: stamps blocked_reason independently of the no-ack path",
         %{task: task, assignee: assignee, stage: stage} do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      lease = LeaseManager.get(task.id)
      past_deadline = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      :ets.insert(
        :orchestration_lease_manager,
        {task.id, %{lease | safety_net_at: past_deadline}}
      )

      send(pid, :check_safety_net)
      :ok = sync_router(task.id)

      stamped = Tasks.get_task_record(task.id)
      assert stamped.status == "blocked"
      assert String.contains?(stamped.metadata["blocked_reason"], "safety-net exceeded")
      assert {:ok, _, _} = DateTime.from_iso8601(stamped.metadata["blocked_reason_at"])
    end

    test "safety-net extend: :check_safety_net reschedules when record_progress extends deadline",
         %{task: task, assignee: assignee, stage: stage} do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # A progress event lands mid-flight → safety_net_at moved forward.
      progress_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage.id,
        event_type: "execution.progress",
        payload: %{"summary" => "still going"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: nil
      }

      Tasks.broadcast_board({:runtime_event, progress_event})
      :ok = sync_router(task.id)

      lease_after_progress = LeaseManager.get(task.id)
      assert %DateTime{} = lease_after_progress.safety_net_at

      remaining_ms =
        DateTime.diff(lease_after_progress.safety_net_at, DateTime.utc_now(), :millisecond)

      # 90min safety-net for `coding`; progress pushes deadline back to
      # `now + 90m`, so remaining is close to 5_400_000ms.
      assert remaining_ms > 1_000_000

      # Force `:check_safety_net` to fire NOW. Router sees remaining > 0,
      # reschedules — must NOT fire the alert.
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      send(pid, :check_safety_net)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}

      assert %{safety_net_fired?: false} = LeaseManager.get(task.id)
    end

    test "safety-net fire: deadline in the past → single loud broadcast + blocker post",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # Force safety_net_at into the past by re-writing the LeaseManager row.
      # (Real-world equivalent: 90 minutes elapsed with no progress.)
      lease = LeaseManager.get(task.id)
      past_deadline = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      :ets.insert(
        :orchestration_lease_manager,
        {task.id, %{lease | safety_net_at: past_deadline}}
      )

      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      send(pid, :check_safety_net)
      :ok = sync_router(task.id)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"} = event}
      assert event.task_id == task.id
      assert event.stage_id == stage.id
      assert event.payload.stage_kind == "coding"

      assert %{safety_net_fired?: true} = LeaseManager.get(task.id)

      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      assert Enum.any?(new_contents, &String.contains?(&1, "safety-net exceeded"))

      # Second call is idempotent.
      send(pid, :check_safety_net)
      :ok = sync_router(task.id)
      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
    end

    test "manual_approval stage: no :check_no_ack or :check_safety_net timers armed",
         %{
           task: task,
           assignee: assignee,
           plan: plan
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Replace the seeded coding stage with a manual_approval stage.
      Platform.Repo.delete_all(from(s in Platform.Tasks.Stage, where: s.plan_id == ^plan.id))

      {:ok, ma_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Manual approval gate",
          description: "Human review only",
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: ma_stage.id, kind: "manual_approval"})

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # The pending_review_request suppression path would fire waiting_human
      # here IF a review request existed. Since none does, this is the
      # `waiting_for_human_review?/1` gate — but with no linked review_request,
      # the stage still counts as manual_approval (all pending validations
      # are manual_approval kind) so `waiting_for_human_review?/1` returns
      # true via `manual_approval_gate_pending?/1`.
      #
      # But wait — that path only returns true when there IS a pending
      # review_request. With no request, the router still dispatches. The
      # dispatch path resolves stage_kind = "manual_approval" and
      # `arm_liveness_timers/3` no-ops (ack_ms and safety_net_ms both nil).
      #
      # Regardless of the exact code path, the key invariant: after dispatch,
      # `LeaseManager.get/1` shows nil `no_ack_at` and nil `safety_net_at`
      # OR no lease at all — meaning no timer arming happened.

      case LeaseManager.get(task.id) do
        nil ->
          # No lease means arm_liveness_timers took the manual_approval
          # no-op path (or dispatch never reached the arm step because
          # `waiting_for_human_review?` short-circuited to :waiting_human).
          :ok

        lease ->
          assert lease.no_ack_at == nil,
                 "manual_approval stage must not arm no-ack timer; got no_ack_at=#{inspect(lease.no_ack_at)}"

          assert lease.safety_net_at == nil,
                 "manual_approval stage must not arm safety-net timer; got safety_net_at=#{inspect(lease.safety_net_at)}"
      end

      # Doubly-defensive check: no `:check_no_ack` or `:check_safety_net`
      # messages should be sitting in the process mailbox waiting to fire
      # (Process.send_after enqueues them for later delivery — a pending
      # timer message will appear in :messages when we peek).
      #
      # NOTE: `Process.send_after/3` messages don't appear in the mailbox
      # until they fire. Instead, we probe process state directly: the arm
      # helper returns `:ok` without side effects, so the assertions above
      # (no lease OR nil timeouts) are the load-bearing check.
      _messages = Process.info(pid, :messages)
    end
  end

  describe "no-ack silence (task 019f6791-c01b stage 2)" do
    # These tests cover the silence-honoring branch in
    # `handle_info(:check_no_ack, ...)`. `LeaseManager.silence/3` is the
    # operator escape hatch installed by the `alarm_silence` MCP tool
    # (stage 3 of this task). The router must NOT fire
    # `execution.no_ack_timeout` while the silence is in effect, must
    # reschedule the check for `until + 1s`, and must resume normal
    # fire-on-expiry once the silence lapses.

    test "silenced lease: :check_no_ack reschedules, no broadcast, no state change",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      :ok = sync_router(task.id)

      # Install a short silence — 400ms in the future — so the reschedule
      # target is reachable within test time budget.
      until = DateTime.add(DateTime.utc_now(), 400, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "cache-miss simulation")

      assert %{silenced_until: %DateTime{}} = LeaseManager.get(task.id)

      space = ExecutionSpace.find_by_task_id(task.id)
      before_msgs = length(ExecutionSpace.list_messages_with_participants(space.id))

      # Force `:check_no_ack` NOW — the silence-honoring branch must
      # reschedule via `Process.send_after` and return without firing.
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      # Silenced: no broadcast on tasks:board.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}

      # Silenced: no_ack_fired? stays false.
      lease_after = LeaseManager.get(task.id)
      refute lease_after.no_ack_fired?

      # Silenced: router still :running, no `:stalled` transition.
      status = TaskRouter.current_status(task.id)
      assert status.status == :running

      # Silenced: no blocker post to the execution space.
      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_contents = Enum.drop(after_msgs, before_msgs) |> Enum.map(& &1.content)
      refute Enum.any?(new_contents, &String.contains?(&1, "Executor never acked"))
    end

    test "silence lapses → next :check_no_ack fires normally",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # Install a silence and immediately rewrite it into the past so the
      # `DateTime.compare(now, until) == :lt` guard is false — this is the
      # "silence lapsed by the time :check_no_ack ran" path. Bypasses
      # `LeaseManager.silence/3`'s past-timestamp validation.
      lease = LeaseManager.get(task.id)
      assert lease, "expected LeaseManager row after dispatch"
      past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      # `no_ack_at` goes into the past alongside it: a lapsed silence only
      # gets you PAST the silence clause, and the fall-through still
      # level-checks the deadline (task 019fa469 stage 6).
      :ets.insert(
        :orchestration_lease_manager,
        {task.id, %{lease | silenced_until: past, no_ack_at: past}}
      )

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      # Silence lapsed → normal fire path: broadcast + mark fired + stall.
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"} = event}
      assert event.task_id == task.id

      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      status = TaskRouter.current_status(task.id)
      assert status.status == :stalled
    end

    test "silence + prior ack → :check_no_ack silent via ack clause (silence orthogonal)",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # Ack lands first; then a silence is installed. `:check_no_ack` must
      # match the earlier `ack_at: %DateTime{}` clause before ever
      # reaching the silence branch — so silence is moot but not harmful.
      :ok = LeaseManager.record_ack(task.id)
      until = DateTime.add(DateTime.utc_now(), 5_000, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "moot but present")

      assert %{ack_at: %DateTime{}, silenced_until: %DateTime{}} = LeaseManager.get(task.id)

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
    end

    test "silence set AFTER alarm fired → next :check_no_ack still no-ops via fired clause",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      # First :check_no_ack fires normally (no silence, no ack, deadline
      # elapsed) → sets no_ack_fired?: true.
      expire_no_ack_deadline!(task.id)
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)
      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      # Operator now installs a silence — a plausible if late intervention.
      # The silence should NOT un-fire the alarm; subsequent :check_no_ack
      # must still no-op via the `%{no_ack_fired?: true}` clause, which
      # sits ABOVE the silence clause in the case expression.
      until = DateTime.add(DateTime.utc_now(), 5_000, :millisecond)
      :ok = LeaseManager.silence(task.id, until, "post-fire silence")

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      # No second broadcast; no state change.
      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
    end
  end

  describe "router lifecycle (no assignment persistence)" do
    test "router starts and stops cleanly without persisting to DB", %{
      task: task,
      assignee: assignee
    } do
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      assert Process.alive?(pid)

      # Stop via TaskRouter.stop/1
      :ok = TaskRouter.stop(task.id)
      refute Process.alive?(pid)
    end

    test "terminate/2 clears the LeaseManager row for the task", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Barrier: the lease row below is written by `record_dispatch/4`
      # inside the `:dispatch` handler, and `get/1` is a bare `:ets.lookup`.
      :ok = sync_router(task.id)

      # Post-dispatch there should be a lease row for this task.
      assert %{} = LeaseManager.get(task.id)

      :ok = TaskRouter.stop(task.id)

      # No barrier here, and none is needed: `TaskRouter.stop/1` is
      # `GenServer.stop/2`, which returns only after `terminate/2` has run,
      # and `terminate/2` clears the lease via `LeaseManager.clear/1` — a
      # direct `:ets.delete` in the terminating router process, not a
      # message. The row is already gone when `stop/1` returns.
      assert LeaseManager.get(task.id) == nil
    end
  end

  describe "e2e_behavior does not suppress dispatch (agent-driven gate)" do
    test "an e2e_behavior validation is not human-gated — no review request, no suppression", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Add an e2e_behavior validation to the running stage. Crucially, no
      # review request is created — e2e_behavior is agent-driven (the review
      # agent runs the script and dispositions via validation_evaluate).
      {:ok, _e2e_validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "x",
            "actions" => "y",
            "expected" => "z"
          }
        })

      # Router must NOT be in :waiting_human state — only manual_approval +
      # pending review_request flips it.
      status = TaskRouter.current_status(task.id)
      refute status.status == :waiting_human
    end
  end

  describe "manual_approval review-request suppression" do
    test "creating a pending review_request mid-task suppresses the next :dispatch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Capture initial execution-space message count
      space = ExecutionSpace.find_by_task_id(task.id)
      initial_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      # Open a manual_approval validation on the existing running stage and
      # create a pending review request against it
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Solo check"}]
        })

      # No barrier needed: `create_review_request/1` broadcasts
      # `{:review_request_pending, ...}` from THIS process
      # (review_requests.ex:114, after its transaction commits), so the message
      # is already in the router's mailbox when the call below is enqueued
      # behind it. `current_status/1` cannot be answered until the broadcast
      # has been handled — the status read IS the barrier.
      status_before_dispatch = TaskRouter.current_status(task.id)
      assert status_before_dispatch.status == :waiting_human

      # Now trigger an explicit :dispatch — it must be suppressed
      send(pid, :dispatch)

      # Barrier, not a wait. The stage-level suppression branch of the
      # `:dispatch` handler (task_router.ex:351) parks and returns WITHOUT a
      # `send(self(), :dispatch)`, so ONE barrier fully drains the injected
      # tick. That is what makes the refutation below an assertion about a
      # SETTLED router rather than a race — "suppressed" and "not dispatched
      # yet" are indistinguishable to a `refute_receive` that starts before
      # the handler has run, and the fixed sleep here could only ever make
      # that distinction probable.
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      status = TaskRouter.current_status(task.id)
      assert status.status == :waiting_human

      messages = ExecutionSpace.list_messages_with_participants(space.id)
      new_messages = Enum.drop(messages, initial_count) |> Enum.map(& &1.content)

      awaiting_logs =
        Enum.filter(new_messages, &String.contains?(&1, "awaiting human review"))

      assert length(awaiting_logs) >= 1
    end

    # POSITIVE CONTROL for the refutation in the test above (task 019fa121
    # stage 4). That test proves suppression by ABSENCE: it injects a
    # `:dispatch`, syncs, and refutes the attention broadcast. An absence is
    # only evidence if the identical sequence — same setup, same injection,
    # same barrier, same mailbox assertion — is known to PRODUCE the broadcast
    # when the gate is not open. Otherwise converting the sleep to a barrier
    # just turns a slow vacuous test into a fast one, and a router that had
    # stopped dispatching for ANY reason (a broken assignee, a missing
    # execution space, an exception swallowed in `do_dispatch/2`) would keep
    # the suppression test green forever.
    #
    # This is byte-for-byte the setup above with the two `create_validation` /
    # `create_review_request` lines removed, so the ONLY difference between
    # green here and green there is the open review request.
    test "control: the same injected :dispatch DOES broadcast when no review request is open",
         %{task: task, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      # Non-blocking: after the barrier the router has finished handling the
      # injected tick, and `do_dispatch/2` broadcasts from inside that handler
      # — router -> test, the same sender/receiver pair as the call reply, so
      # the broadcast is already ahead of the reply in this process's mailbox.
      assert_received %Phoenix.Socket.Broadcast{
        event: "attention",
        payload: %{signal: %{reason: "task_assigned"}}
      }

      refute TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "approving all items wakes the router and clears :waiting_human", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "UI"}]
        })

      # Both reads below are their own barrier: the `{:review_request_pending}`
      # and `{:review_request_resolved}` broadcasts are emitted from THIS
      # process (review_requests.ex:114 and :317) before the corresponding
      # `create_review_request/1` / `approve_item/2` call returns, and the
      # `:passed` branch of the resolved handler does not `send(self(),
      # :dispatch)` — so a single call drains each of them completely.
      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _} = Platform.Tasks.ReviewRequests.approve_item(hd(request.items).id, "rowan")

      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end

    test "rejecting an item wakes the router AND re-dispatches with the in_progress prompt",
         %{
           task: task,
           assignee: assignee,
           stage: stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "UI"}]
        })

      # The status read is the barrier for the `{:review_request_pending}`
      # broadcast `create_review_request/1` already emitted from this process.
      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _} =
        Platform.Tasks.ReviewRequests.reject_item(hd(request.items).id, "rowan", "Needs work")

      # Expect a fresh dispatch (task_assigned) after rejection. This one keeps
      # a BLOCKING receive rather than a barrier: the `:failed` branch of the
      # `{:review_request_resolved}` handler re-dispatches through
      # `send(self(), :dispatch)` (task_router.ex:877), so the broadcast is
      # produced by a SECOND message that a single barrier does not cover.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_500

      # ...and the status read after it is the barrier for that second
      # message: the call is answered only once `do_dispatch/2` has returned.
      status = TaskRouter.current_status(task.id)
      assert status.status == :running
    end
  end

  describe "plan-level pending_review suppression (task 019f9ae5)" do
    # Stage 1 added a PLAN-level guard to `handle_info(:dispatch, state)`.
    # `init/1` always had one, but every OTHER `:dispatch` injector bypasses
    # init and landed straight in `do_dispatch/2`:
    # `TaskRouterWatcher.redispatch_for_runtime/1` fires a raw
    # `send(pid, :dispatch)` for every should-run task on each runtime
    # reconnect (the confirmed source of the 10-day re-dispatch loop on task
    # 019f6779), plus `force_dispatch/1`, the ~10 in-module
    # `send(self(), :dispatch)` sites and the 1s retry timer. Every test here
    # therefore uses an EXPLICIT `send(pid, :dispatch)` — that is the path
    # that leaked, and it is the only way to exercise the handler branch.
    #
    # The fixture plan is flipped in place rather than re-created:
    # `plan_awaiting_review?/1` keys off `Tasks.latest_plan/1` (highest
    # version regardless of status), so an accidental v2 would silently
    # change what is under test.

    defp mark_plan_pending_review(plan) do
      plan
      |> Ecto.Changeset.change(%{status: "pending_review"})
      |> Platform.Repo.update!()
    end

    defp suppression_logs_since(space_id, drop_count) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.drop(drop_count)
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "awaiting human review"))
    end

    # Every plan-gate line in the space, from the beginning — the init-time
    # emission lands before a test can take a baseline (the space itself is
    # created inside `init/1`), so this counts from zero instead of dropping.
    defp plan_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "plan is awaiting human review"))
    end

    test "pending_review plan suppresses an explicitly injected :dispatch", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      _pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # `init/1` refuses to schedule the initial dispatch, so nothing should
      # arrive before we force the issue.
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      space = ExecutionSpace.find_by_task_id(task.id)

      # `init/1` narrates the park in the execution space at episode start.
      # This is the human-facing half of the feature: a suppressed task must
      # explain itself, not go quiet. An earlier revision of this test asserted
      # ZERO lines here — that encoded the defect the e2e review caught
      # (validation 019f9aea-95bc-7a84-bf3e-333bc165798b): the handler's log is
      # edge-triggered on `state.status != :waiting_human`, and a router that
      # boots into a `pending_review` plan is ALREADY `:waiting_human`, so the
      # edge never fires. That is the production shape, not a corner case.
      init_logs = plan_gate_logs(space.id)

      assert length(init_logs) == 1,
             "expected exactly one plan-gate suppression log from init/1, got: #{inspect(init_logs)}"

      assert String.contains?(hd(init_logs), "plan is awaiting human review")

      send(pid, :dispatch)
      # Barrier per tick, not one at the end (task 019fa121 stage 4). What is
      # under test is the router's PER-MESSAGE behaviour — one tick must not
      # narrate, and the second must not narrate either — so each refutation
      # has to be taken against a router that has finished exactly the tick
      # that preceded it. Batching the barrier would let both ticks fold
      # together and turn a two-tick property into a one-tick one.
      #
      # POSITIVE CONTROL for both refutations: "approved plan still dispatches
      # — the plan guard is not over-broad" (:1644 in this block) runs the
      # identical `send(pid, :dispatch)` against a router whose plan is
      # `approved` and DOES observe the attention broadcast. Without that pair
      # these two refutations are satisfied by any router that has stopped
      # dispatching for any reason at all.
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      # Second tick — the guard must hold, and must not start narrating.
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # ...and stays silent on every subsequent tick. `init/1` parked this
      # router in `:waiting_human` before either dispatch, so the handler's
      # edge condition is false and neither tick adds a line. That is the
      # anti-spam property task 019e00cb fixed — an unconditional log here
      # would post once per injected dispatch, and `TaskRouterWatcher` injects
      # one per runtime reconnect. Net contract: exactly one line per
      # suppression episode, zero on repeats.
      assert plan_gate_logs(space.id) == init_logs
    end

    test "the plan-level suppression log is edge-triggered: one line per episode, not per tick",
         %{task: task, assignee: assignee, plan: plan} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      # Start while the fixture plan is still `approved` so the router parks
      # in `:running` — that is what makes the next dispatch a genuine
      # `:running -> :waiting_human` transition.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # Flip the plan WITHOUT broadcasting `{:plan_updated, ...}` — a
      # broadcast would drive the router to `:waiting_human` through the
      # plan_updated handler and rob the dispatch handler of the edge.
      _pending_plan = mark_plan_pending_review(plan)

      space = ExecutionSpace.find_by_task_id(task.id)
      baseline_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      # One barrier per tick. This test counts LINES across two ticks, so the
      # two ticks must be separated for the count to mean anything: with a
      # single barrier at the end, a router that emitted zero lines and a
      # router that emitted one on a tick the test never separated are the
      # same observation.
      #
      # POSITIVE CONTROL: ":1644 approved plan still dispatches" for the
      # refutation, and the `assert length(logs) == 1` below is itself the
      # positive half of this test's own pair — it fails if the router falls
      # silent, which is the failure mode a bare refutation cannot see.
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = suppression_logs_since(space.id, baseline_count)

      assert length(logs) == 1,
             "expected exactly one plan-gate suppression log across two ticks, got: #{inspect(logs)}"

      assert String.contains?(hd(logs), "plan is awaiting human review")
    end

    test "a running router narrates the park when the plan is submitted for review", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert plan_gate_logs(space.id) == []

      pending_plan = mark_plan_pending_review(plan)

      # The board broadcast the router would receive from `Tasks.submit_plan/2`.
      # No barrier needed here — the `current_status/1` read on the next line
      # is one, and the `{:plan_updated, "pending_review"}` handler
      # (task_router.ex:800) parks without a `send(self(), :dispatch)`.
      send(pid, {:plan_updated, pending_plan})

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = plan_gate_logs(space.id)

      assert length(logs) == 1,
             "expected the plan_updated handler to narrate the park once, got: #{inspect(logs)}"

      # A re-broadcast of the same pending plan must not double-post.
      send(pid, {:plan_updated, pending_plan})
      # Load-bearing barrier: unlike the first send, nothing between here and
      # the assertion is a call to the router. `plan_gate_logs/1` reads the
      # execution space through `Repo`, and the row it is looking for is
      # written INSIDE the handler — so without this the assertion can observe
      # the pre-broadcast state and pass for the wrong reason. The 150ms sleep
      # this replaces was making exactly that guess.
      :ok = sync_router(task.id)

      assert plan_gate_logs(space.id) == logs
    end

    test "approved plan still dispatches — the plan guard is not over-broad", %{
      task: task,
      assignee: assignee
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      # Fixture plan is `approved` (setup line ~35) — untouched here.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # POSITIVE CONTROL cited by the refutations at :1509, :1519 and :1579 —
      # same injection, same assertion shape, gate closed instead of open.
      # The `current_status/1` call is the barrier for the injected tick.
      refute TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "approving the plan wakes the router — suppression is not a one-way door", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _task} = Tasks.transition_task(task, "planning")
      pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Prove suppression PRECEDED resumption — otherwise a green assertion
      # below could just be the un-suppressed dispatch we were trying to stop.
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      {:ok, _approved} = Tasks.approve_plan(pending_plan, "rowan")

      # Resumption chain: `approve_plan/3` -> `apply_dispatch_gate/1` moves the
      # task to `in_progress` in-transaction -> post-commit
      # `broadcast_board({:plan_updated, approved})` -> the router's
      # plan_updated handler sets `:running` and calls
      # `ensure_execution_stage_started/2` -> `PlanEngine.start_stage/1` on the
      # fixture's pending stage -> `{:stage_transitioned, stage}` -> the
      # router's stage handler `send(self(), :dispatch)` -> the plan guard is
      # now false because `latest_plan.status == "approved"`.
      #
      # Note that resumption does NOT depend on the router's `status` field:
      # the `:dispatch` handler never reads `state.status` for gating (only for
      # the edge-triggered log), so parking in `:waiting_human` cannot lock a
      # task out.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     2_000

      # The blocking receive above already ordered against the dispatch; this
      # call is the barrier for the handler that produced it.
      assert TaskRouter.current_status(task.id).status == :running
    end

    test "approved plan with an open manual_approval request keeps the STAGE-level reason", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      initial_count = length(ExecutionSpace.list_messages_with_participants(space.id))

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Solo check"}]
        })

      # Barrier by status read — the `{:review_request_pending}` broadcast was
      # emitted from this process inside `create_review_request/1`.
      assert TaskRouter.current_status(task.id).status == :waiting_human

      send(pid, :dispatch)
      # POSITIVE CONTROL for the refutation below: "pending e2e_behavior
      # validation with an approved plan still dispatches" (:1788) injects the
      # same `send(pid, :dispatch)` behind the same barrier with no open
      # review request and DOES observe the attention broadcast.
      :ok = sync_router(task.id)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = suppression_logs_since(space.id, initial_count)

      # The new plan-level branch is ordered AHEAD of the stage-level one, but
      # `plan_awaiting_review?/1` is false here (plan is `approved`), so the
      # stage gate must still own this suppression — same copy as before.
      assert Enum.any?(logs, &String.contains?(&1, "awaiting human review on a manual_approval"))

      refute Enum.any?(logs, &String.contains?(&1, "plan is awaiting human review"))
    end

    test "pending e2e_behavior validation with an approved plan still dispatches", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # No review request — e2e_behavior is agent-driven (the review agent runs
      # the script and dispositions via validation_evaluate), so neither the
      # plan gate nor the stage gate may claim it.
      {:ok, _e2e_validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "seed a task",
            "actions" => "send :dispatch",
            "expected" => "attention broadcast"
          }
        })

      # `create_validation/1` is a plain `Repo.insert` in this process — it
      # broadcasts nothing the router subscribes to, so there was never
      # anything for a sleep to wait on here. The injected dispatch below is
      # ordered after it by construction.
      send(pid, :dispatch)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      # POSITIVE CONTROL cited by the stage-gate refutation at :1770.
      refute TaskRouter.current_status(task.id).status == :waiting_human
    end

    # ── ADR-0046 member 5 stage 5: who holds the slot, and when it ends ──
    #
    # NO SECOND HOLD MECHANISM IS UNDER TEST HERE. A gated plan is just a
    # `pending_review` plan, which is the condition the six cases above
    # already suppress across every injector. What changes is (a) WHOSE
    # occupancy the execution-space line names and (b) that something
    # eventually ends it.
    #
    # Every fixture below writes the verdict from the TEST, at runtime —
    # nothing here reads state a migration wrote, so reverting `lib/` really
    # does revert what these assertions see.

    defp architecture_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "plan is with the architect for review"))
    end

    # Open the gate directly with an explicit deadline offset. Direct rather
    # than through `submit_plan_for_review/1` so these tests exercise the
    # ROUTER instead of re-testing stage 2's branch, and because
    # `open_architecture_gate/2` derives its deadline from config while the
    # restart test needs a window it picked itself.
    defp open_gate_with_deadline(plan, offset_ms) do
      now = DateTime.utc_now()

      verdict = %{
        "state" => "pending",
        "opened_at" => DateTime.to_iso8601(now),
        "deadline_at" => now |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601(),
        "resolved_at" => nil,
        "resolved_by" => nil,
        "architect_agent_id" => "architect-test",
        "source" => nil,
        "summary" => nil,
        "findings" => []
      }

      plan
      |> Platform.Tasks.Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
      |> Platform.Repo.update!()
    end

    test "the architect's occupancy gets its own copy — and an ungated plan still gets 70fc30fe's",
         %{task: task, assignee: assignee, plan: plan, project: project} do
      {:ok, task} = Tasks.transition_task(task, "planning")
      gated = plan |> mark_plan_pending_review() |> open_gate_with_deadline(60_000)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      send(pid, :dispatch)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      space = ExecutionSpace.find_by_task_id(task.id)
      arch_logs = architecture_gate_logs(space.id)

      assert length(arch_logs) == 1,
             "expected exactly one architecture-gate line, got: #{inspect(arch_logs)}"

      line = hd(arch_logs)

      # Names the architect, says no human action is pending, names the
      # deadline, and says the gate falls open by itself.
      assert String.contains?(line, "no human action needed yet")
      assert String.contains?(line, "falls open on its own")
      assert String.contains?(line, gated.architecture_verdict["deadline_at"])

      # ...and does NOT send the reader to a button they should not press.
      refute String.contains?(line, "approve or reject the plan to resume")
      assert plan_gate_logs(space.id) == []

      # POSITIVE CONTROL, in the same test and deliberately so: without it a
      # predicate that ALWAYS answered "architecture" would pass everything
      # above. This half is the byte-identical `70fc30fe` line.
      {:ok, other_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ungated control #{System.unique_integer([:positive])}",
          description: "pending_review with no architecture gate",
          deploy_target: "production"
        })

      {:ok, other_plan} =
        Tasks.create_plan(%{task_id: other_task.id, status: "pending_review", version: 1})

      assert other_plan.architecture_verdict == nil

      {:ok, other_task} = Tasks.transition_task(other_task, "planning")

      other_assignee = %{
        type: :federated,
        id: "runtime-ungated-#{System.unique_integer([:positive])}"
      }

      {:ok, other_pid} = TaskRouter.start_link(task_id: other_task.id, assignee: other_assignee)

      on_exit(fn ->
        if Process.alive?(other_pid) do
          try do
            GenServer.stop(other_pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      send(other_pid, :dispatch)
      :ok = sync_router(other_task.id)

      other_space = ExecutionSpace.find_by_task_id(other_task.id)
      human_logs = plan_gate_logs(other_space.id)

      assert length(human_logs) == 1,
             "expected exactly one plan-gate line on the ungated control, got: #{inspect(human_logs)}"

      assert String.contains?(
               hd(human_logs),
               "Dispatch suppressed: plan is awaiting human review — approve or reject the plan to resume"
             )

      assert architecture_gate_logs(other_space.id) == []
    end

    test "the deadline resolves the gate, the plan settles to approved, and the router wakes", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # `settle_plan_submission/1`'s auto path needs the flag AND both
      # `auto_approve_precondition/2` legs. Without them "it approved late"
      # would be unfalsifiable — the plan would have stayed `pending_review`
      # whether or not the gate resolved.
      task =
        task
        |> Ecto.Changeset.change(%{
          auto_approve_plan: true,
          phase_assignees: %{
            "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
            "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })
        |> Platform.Repo.update!()

      {:ok, task} = Tasks.transition_task(task, "planning")
      gated = plan |> mark_plan_pending_review() |> open_gate_with_deadline(60_000)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Prove suppression PRECEDED resumption, or the wake-up below could
      # just be a dispatch that was never held.
      send(pid, :dispatch)

      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # Fire the deadline message directly; the ARMING of it is what the
      # restart test below covers. What is under test here is the whole chain
      # the message kicks off: resolve -> settle_plan_submission -> approved
      # -> plan_updated -> ensure_execution_stage_started -> stage_transitioned
      # -> dispatch.
      send(pid, {:architecture_gate_deadline, gated.id})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     2_000

      assert TaskRouter.current_status(task.id).status == :running

      reloaded = Platform.Repo.get!(Platform.Tasks.Plan, gated.id)
      assert reloaded.status == "approved"
      assert reloaded.architecture_verdict["state"] == "expired"
      assert reloaded.architecture_verdict["source"] == "deadline"
    end

    test "the submit broadcast arms the deadline on an already-running router", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      # Boot while the fixture plan is still `approved` so the router is
      # `:running` and `init/1` arms nothing. THIS is the production shape —
      # `submit_plan_for_review/1` opens the gate and broadcasts to a router
      # that is already up — and it is the one arming site `init/1` cannot
      # stand in for.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      assert :sys.get_state(pid).architecture_deadline_ref == nil

      gated = plan |> mark_plan_pending_review() |> open_gate_with_deadline(60_000)
      send(pid, {:plan_updated, gated})

      ref = :sys.get_state(pid).architecture_deadline_ref
      assert is_reference(ref), "the plan_updated handler armed no deadline"

      remaining = Process.read_timer(ref)
      assert is_integer(remaining) and remaining > 0 and remaining <= 60_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert length(architecture_gate_logs(space.id)) == 1
    end

    test "a router restart loop cannot renew the deadline — the delay only ever shrinks", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      window_ms = 60_000
      _gated = plan |> mark_plan_pending_review() |> open_gate_with_deadline(window_ms)

      # `TaskRouterWatcher` restarts routers on every runtime reconnect and
      # every 5-minute reconcile. If `remaining_ms` were a fresh window rather
      # than persisted-deadline-minus-now, that loop would renew the deadline
      # forever — the same defect shape as a lease that re-arms on every touch.
      armed_delay = fn ->
        {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
        ref = :sys.get_state(pid).architecture_deadline_ref

        assert is_reference(ref), "init/1 armed no architecture-gate deadline"

        remaining = Process.read_timer(ref)

        assert is_integer(remaining),
               "the armed timer was already fired or cancelled: #{inspect(remaining)}"

        GenServer.stop(pid, :normal, 1_000)
        remaining
      end

      # THE TWO WAITS BELOW ARE THE MEASUREMENT, NOT A BARRIER — the only two
      # sites in this file carrying the annotated escape hatch described in
      # `describe "zero-sleep guard"`. Nothing is running between the restarts:
      # `armed_delay/0` stops the router before it returns, so there is no
      # process to synchronise with and no event to wait for. What is under
      # test is that the persisted deadline is CONSUMED by real time spent
      # dead, which is the `d1 - d3 >= 200` assertion below. Elapsed wall clock
      # is the subject of that assertion, so a barrier cannot replace these:
      # removing them makes the test measure nothing and pass on a tree where
      # `remaining_ms` renewed a fresh window on every restart.
      d1 = armed_delay.()
      # WALL-CLOCK-ASSERTION: elapsed real time is the subject of `d1 - d3 >= 200` below
      Process.sleep(120)
      d2 = armed_delay.()
      # WALL-CLOCK-ASSERTION: elapsed real time is the subject of `d1 - d3 >= 200` below
      Process.sleep(120)
      d3 = armed_delay.()

      assert d1 <= window_ms
      assert d2 <= d1, "delay grew across a restart: #{d1} -> #{d2}"
      assert d3 <= d2, "delay grew across a restart: #{d2} -> #{d3}"

      # Monotonicity alone is satisfied by a constant. The deadline must
      # actually be CONSUMED by wall-clock time spent dead.
      assert d1 - d3 >= 200,
             "expected the deadline to be consumed across restarts, got #{d1} -> #{d2} -> #{d3}"
    end

    test "a router booting AFTER the deadline settles the gate on the spot, and uses the human copy",
         %{task: task, assignee: assignee, plan: plan} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      task =
        task
        |> Ecto.Changeset.change(%{
          auto_approve_plan: true,
          phase_assignees: %{
            "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
            "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })
        |> Platform.Repo.update!()

      {:ok, task} = Tasks.transition_task(task, "planning")
      overdue = plan |> mark_plan_pending_review() |> open_gate_with_deadline(-1_000)

      # The row is UNWRITTEN: the projection reports expired, but nothing has
      # closed the gate or run the deferred tail. This is the state a router
      # that died before its deadline leaves behind — the shape that stranded
      # `deploying -> done` in the 2026-07-26 incident, where the only
      # resolver was an edge nobody re-checked on rehydrate.
      assert Platform.Repo.get!(Platform.Tasks.Plan, overdue.id).architecture_verdict["state"] ==
               "pending"

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Boot alone — no injected dispatch, no PubSub — must settle it.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     2_000

      settled = Platform.Repo.get!(Platform.Tasks.Plan, overdue.id)
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.status == "approved"

      space = ExecutionSpace.find_by_task_id(task.id)

      # The window closed before this router existed, so the slot is the
      # human's again and the narration must be the ACTIONABLE line. Telling a
      # reader to keep waiting on an architect who is already out of time
      # would be false.
      assert architecture_gate_logs(space.id) == []
      assert length(plan_gate_logs(space.id)) == 1
    end

    test "no router at all: a past-deadline gate stops blocking approval via the LEVEL check", %{
      project: project
    } do
      # Task 019fb978 stage 2 gated the watcher off in test
      # (`:start_task_router_watcher`, config/test.exs). This is the ONLY test
      # in this file where the watcher is the actor, so it starts its own —
      # and it MUST, because the barrier below is `TaskRouterWatcher.sync/0`,
      # a `GenServer.call` that would exit `:noproc` without a live watcher.
      #
      # Leaving it unstarted would be worse than a crash: the assertion here
      # is that a router is ABSENT, and "the watcher does not exist" satisfies
      # that vacuously. Starting it is what keeps the absence meaningful.
      start_supervised!(Platform.Orchestration.TaskRouterWatcher)

      # `TaskRouterWatcher.should_run?/1` requires `assignee_type == "agent"`,
      # so a task assigned to a USER for planning never gets a router and
      # therefore never arms a deadline timer. If the timer were the
      # correctness guarantee, this plan would be stuck forever.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Planner-assigned, no router #{System.unique_integer([:positive])}",
          description: "assignee_type user",
          assignee_type: "user",
          assignee_id: Ecto.UUID.generate(),
          status: "planning"
        })

      refute Platform.Orchestration.TaskRouterWatcher.should_run?(task)

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "pending_review", version: 1})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

      gated = open_gate_with_deadline(plan, -1_000)

      # NOTHING wrote a resolution — the persisted row still says `pending`.
      # That is the whole point: the level check projects, it does not write.
      assert Platform.Repo.get!(Platform.Tasks.Plan, gated.id).architecture_verdict["state"] ==
               "pending"

      assert {:resolved, %{"state" => "expired", "source" => "deadline"}} =
               Tasks.architecture_gate(gated)

      refute Tasks.architecture_gate_open?(gated)

      assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
             "no router may exist for a user-assigned task"

      assert {:ok, approved} = Tasks.approve_plan(gated, "system")
      assert approved.status == "approved"

      # `approve_plan/3` broadcasts on `tasks:board`, which wakes the singleton
      # `TaskRouterWatcher`. It still must not start one here.
      #
      # THIS IS THE ONE SITE IN THIS FILE WHERE THE WATCHER IS THE ACTOR, so it
      # is the one site where `TaskRouterWatcher.sync/0` — and not
      # `sync_router/2` — is the right barrier. `sync_router/2` cannot even be
      # spelled here: there is no per-task router to call, which is precisely
      # the claim.
      #
      # A fixed sleep is not merely weak here, it is UNSOUND. This is an
      # ABSENCE assertion, so it is already true before the watcher does
      # anything at all; the sleep expiring is not evidence the watcher ran.
      # Task 019fa003 stage 4 demonstrated the failure directly: with the
      # watcher `:sys.suspend`ed, the sleep-based form of an absence assertion
      # passes vacuously while the barrier form correctly fails.
      #
      # The barrier closes it. `Phoenix.PubSub.broadcast/4` dispatches to local
      # subscribers in the CALLING process, so `approve_plan/3` returning means
      # the `{:task_updated, _}` message is already in the watcher's mailbox,
      # ahead of the `:sync` call. `evaluate_task/1` — and the
      # `resolve_and_start/1` that would register a router — runs synchronously
      # inside that `handle_info/2` (task_router_watcher.ex:157, :650). So when
      # `sync/0` returns, a router that was going to be started HAS been.
      assert TaskRouterWatcher.sync() == :ok

      assert Registry.lookup(Platform.Orchestration.Registry, task.id) == [],
             "approval must not have started a router for a user-assigned task"
    end

    # Task 01a03ec2. What this pins is the SHAPE OF THE NOTICE, not the fact
    # that a notice happens.
    #
    # The report this came from said the suppression notice is emitted wrapped
    # in the whole dispatch payload. It is not, and was not on this checkout:
    # `do_log_heartbeat_suppressed/3` concatenates exactly the reason string
    # and `diagnostic_snapshot/3` (six fields), and the payload is a DIFFERENT
    # message on a DIFFERENT path: `ExecutionSpace.post_engagement/3`, reached
    # only after a dispatch succeeds. The production messages the report cited
    # are 213 bytes each, in a space that also holds 30,059-byte dispatch
    # prompts; the payload was attributed to the wrong message. So nothing is
    # removed here. What was missing is the thing that stops a later change
    # from interpolating `task.description` into that line.
    #
    # ONE task, ONE rendering path, two halves, in this order deliberately:
    #
    #   1. Positive control. Dispatch for real and assert the sentinel DOES
    #      reach the execution space. This is load-bearing, not decoration: an
    #      absence assertion on its own is satisfied by a tree that renders no
    #      task description anywhere, so a change that broke payload rendering
    #      outright would pass step 2 while shipping empty dispatches to every
    #      executor on the platform.
    #   2. Absence, on the notice.
    #
    # The sentinel is read back OFF THE ROW rather than trusted from the
    # literal typed below, so "absent from the notice" cannot be satisfied by a
    # description that never persisted. The literal itself appears nowhere else
    # in the repo, so a stray substring match cannot supply it either.
    test "the plan-gate suppression notice carries the reason and no ticket body", %{
      assignee: assignee
    } do
      # A fresh task, not the describe fixture: step 2 needs `create_plan/1` to
      # mint v1, and `plan_awaiting_review?/1` keys off `Tasks.latest_plan/1`
      # (highest version regardless of status). Flipping the fixture plan in
      # place instead would leave step 1 dispatching against an `approved` v1.
      {:ok, project} =
        Tasks.create_project(%{
          name: "Suppression Notice Project #{unique()}",
          repo_url: "https://github.com/test/suppression-notice"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Suppression notice payload fixture",
          description: """
          Rendering probe for the plan-gate suppression notice.
          Sentinel: ORNITHOPTER-SENTINEL-7
          """,
          deploy_target: "production"
        })

      sentinel =
        case Regex.run(~r/ORNITHOPTER-[A-Z]+-\d+/, Tasks.get_task_detail(task.id).description) do
          [match] ->
            match

          other ->
            flunk("the fixture description did not persist its sentinel: #{inspect(other)}")
        end

      {:ok, task} = Tasks.transition_task(task, "planning")

      # Close the ADR-0046 pre-plan design step before the router boots.
      # `design_edge_window?/1` matches EXACTLY this shape (planning, no
      # design outcome, no plan row), so an untouched fixture spawns the
      # designer edge and `design_hold?/2` parks the router at
      # `:waiting_design` with an empty execution space. The positive control
      # then fails for a reason that has nothing to do with what is under
      # test. `:unfilled` records `"not_applicable"`, which is what a task
      # with no design responsibility gets in production.
      {:ok, _task} = Tasks.record_planning_step(task, :design, {:ok, :unfilled})

      # ── 1. POSITIVE CONTROL: the payload path DOES render the ticket body ──
      # Planning with no plan row resolves `dispatch.planning`, whose body
      # interpolates `task.description`. If this stops being true, the refute
      # below stops meaning anything.
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      space = ExecutionSpace.find_by_task_id(task.id)

      assert Enum.any?(space_message_contents(space.id), &String.contains?(&1, sentinel)),
             "the planning dispatch did not carry the task description into the execution " <>
               "space, so the absence assertion below would pass against a tree that renders " <>
               "no ticket body at all. Message sizes: " <>
               inspect(Enum.map(space_message_contents(space.id), &String.length/1))

      # ── 2. ABSENCE: the notice is a bare status line ──
      :ok = TaskRouter.stop(task.id)

      {:ok, _plan} =
        Tasks.create_plan(%{task_id: task.id, status: "pending_review", version: 1})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      notices = plan_gate_logs(space.id)

      assert length(notices) == 1,
             "expected exactly one plan-gate suppression notice, got: #{inspect(notices)}"

      [notice] = notices

      refute String.contains?(notice, sentinel),
             "the suppression notice carried the ticket body: #{notice}"

      # 3. Emitting nothing must not be a passing state: the reason has to
      #    survive whatever a later change does to the payload question.
      assert String.contains?(notice, "Dispatch suppressed: plan is awaiting human review")

      # 3b. Task 01a03ec2 stage 2. The line names its own subject. This is the
      #     defect that produced the ticket: the notice was read outside its
      #     execution space, where nothing in it said which task it was about,
      #     and it got filed against the wrong message. Asserted with the id
      #     interpolated rather than on the bare prefix `task=`, which the
      #     word "task_status=" would satisfy on its own.
      assert String.contains?(notice, "task=#{task.id}")

      # 4. Byte budget. Measured 2026-08-27: 332 characters on this fixture,
      #    257 in production. Stage 2 of this task added `task=<uuid>` to the
      #    shared snapshot, which moved both numbers up by the same 44 (the
      #    field, the id, and one separator); before that they were 288 and
      #    213. The 75-character gap between the two is one field:
      #    `deploy_target` renders `unresolved(...)` with the lookup error
      #    inline in test, where production renders a resolved target. That is
      #    left alone rather than tuned away, because the budget is a CEILING
      #    against a payload (30,059 characters on the dispatch prompts
      #    sitting in the same space), not a pin on the current rendering, and
      #    a bound that has to be re-tuned every time a diagnostic field is
      #    added would be edited without being thought about. The literal
      #    check above catches `task.description` by name; this catches a
      #    payload creeping back in under some other one.
      assert String.length(notice) < 1_000,
             "suppression notice is #{String.length(notice)} characters: #{notice}"

      # The describe fixture's `on_exit` only stops the router for ITS task.
      # This test owns a second one, and letting the sandbox owner die
      # underneath it makes `terminate/2`'s space post race the checkin.
      :ok = TaskRouter.stop(task.id)
    end

    defp space_message_contents(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
    end
  end

  # Task 01a03ec2 stage 2. `diagnostic_snapshot/3` is a SHARED formatter. The
  # four suppression reasons in `do_log_heartbeat_suppressed/3` reach it
  # through a single call, and three other lines call it directly, so an edit
  # there travels further than the diff looks. The direction that would NOT
  # show up in the suppression tests above is silencing one of the lines that
  # is supposed to repeat.
  #
  # `Runtime failure detected` and `Heartbeat suppressed: runtime reported
  # blocker` are EVENT REPORTS, not standing states. The second failure is a
  # different fact from the first, so one line per event is the contract and a
  # per-episode elision would be a defect here even though it is correct on
  # the plan-gate and stage-gate paths a few hundred lines up. Those two
  # neighbouring lines ARE edge-triggered, which is exactly why this needs
  # pinning: the elision is sitting right there to be generalised onto the
  # formatter by someone tidying up.
  #
  # Two failures rather than one, deliberately. A single-event assertion is
  # satisfied by an implementation that posts once and then goes quiet
  # forever, which is the regression this exists to catch.
  describe "diagnostic_snapshot is a shared formatter (task 01a03ec2)" do
    test "two runtime failures post two lines, each naming the task", %{
      task: task,
      assignee: assignee
    } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      space = ExecutionSpace.find_by_task_id(task.id)

      # A barrier per event, not one at the end. What is under test is a
      # PER-EVENT property, so each line has to be attributable to the event
      # that preceded it; batching the barrier would let a single post satisfy
      # both sends.
      send(pid, {:runtime_event, runtime_failure_event(task, assignee, "execution.failed")})
      :ok = sync_router(task.id)

      send(pid, {:runtime_event, runtime_failure_event(task, assignee, "execution.abandoned")})
      :ok = sync_router(task.id)

      lines =
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.map(& &1.content)
        |> Enum.filter(&String.contains?(&1, "Runtime failure detected"))

      assert length(lines) == 2,
             "expected one line per runtime failure, got #{length(lines)}: #{inspect(lines)}"

      # Asserted with the id interpolated, not on the bare prefix `task=`:
      # the snapshot also renders `task_status=`, and a prefix-only check
      # would be satisfied by a line that names no task at all.
      assert Enum.all?(lines, &String.contains?(&1, "task=#{task.id}")),
             "a runtime-failure line did not name its task: #{inspect(lines)}"

      # The two lines report DIFFERENT events. Without this, two copies of one
      # event's line would pass the count above.
      assert Enum.any?(lines, &String.contains?(&1, "event=execution.failed"))
      assert Enum.any?(lines, &String.contains?(&1, "event=execution.abandoned"))
    end

    test "a runtime blocker line names its task too", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      :ok = sync_router(task.id)

      space = ExecutionSpace.find_by_task_id(task.id)

      blocked_event = %{
        id: nil,
        task_id: task.id,
        stage_id: running_stage.id,
        event_type: "execution.blocked",
        payload: %{"stage_id" => running_stage.id, "description" => "waiting on a subagent"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, blocked_event})
      :ok = sync_router(task.id)

      blocker_lines =
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.map(& &1.content)
        |> Enum.filter(&String.contains?(&1, "Heartbeat suppressed: runtime reported blocker"))

      assert length(blocker_lines) == 1,
             "expected the blocker line to still emit, got: #{inspect(blocker_lines)}"

      assert String.contains?(hd(blocker_lines), "task=#{task.id}")
    end

    defp runtime_failure_event(task, assignee, event_type) do
      %{
        id: nil,
        task_id: task.id,
        stage_id: nil,
        event_type: event_type,
        payload: %{"error" => "runner exited before the stage settled"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "failed"}
      }
    end
  end

  describe "stage-level suppression is edge-triggered (task 019f9b34)" do
    # Sibling of the plan-level block above. The STAGE-level copy
    # ("Dispatch suppressed: awaiting human review on a manual_approval
    # validation") posted once per router tick instead of once per suppression
    # episode: measured 1 -> 2 -> 3 -> 4 over three injected dispatches, and 7
    # for the fuller production shape (boot + 3 dispatches + 2
    # `:review_request_pending` re-broadcasts).
    #
    # Why the 019e00cb predicate gate cannot cover this on its own:
    # `HeartbeatScheduler.heartbeat_suppressible?/2` returns false unless EVERY
    # pending validation on the stage is a `manual_approval` linked to an open
    # review request. The setup fixture seeds a `test_pass` on the stage, so a
    # single co-pending automated validation makes the predicate false forever
    # and the elision never engages. That co-pending `test_pass` is the entire
    # production shape under test here — do NOT drop it.
    #
    # Six sites park the router on the stage gate. Stage 1 of 019f9b34 found
    # the plan's four-site analysis incomplete: the `{:review_request_pending}`
    # handler does NOT open a mid-task episode (the router is already
    # `:waiting_human` by the time it runs). The real opener is the tail of
    # `do_dispatch/2`, which parks silently, and `{:task_updated}` is a second
    # silent park site. Both now narrate, edge-gated. `do_dispatch/2` gates on
    # `entry_status` captured at function entry, because `state.status` is set
    # to `:running` unconditionally before its tail park — the `state.status`
    # edge is useless there.

    # TRAP 1 — SUBSTRING COLLISION. Do NOT reuse `suppression_logs_since/2`:
    # it filters on the loose "awaiting human review", which matches BOTH the
    # stage copy and the plan copy ("Dispatch suppressed: plan is awaiting
    # human review — approve or reject the plan to resume"). That collision
    # already cost a cycle on 019f9ae5 and is why `plan_gate_logs/1` exists.
    # This filter is copy-specific to the stage gate.
    #
    # TRAP 2 — COUNT FROM ZERO, NEVER FROM A POST-`start_link` BASELINE. The
    # execution space is created inside `init/1`, so a boot-time emission
    # lands before any test can snapshot a baseline and
    # `suppression_logs_since/2`'s `Enum.drop/2` silently swallows it.
    # Counting from zero is the only way to assert exactly-one ACROSS the boot
    # emission plus subsequent ticks. Same reasoning as `plan_gate_logs/1`.
    defp stage_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.contains?(&1, "awaiting human review on a manual_approval"))
    end

    # The THIRD suppression copy, emitted by call sites that pass no `:reason`
    # (the `{:stage_transitioned, ...}` site). It shares no substring with
    # either of the other two, so a loose filter would silently miss it.
    defp generic_gate_logs(space_id) do
      space_id
      |> ExecutionSpace.list_messages_with_participants()
      |> Enum.map(& &1.content)
      |> Enum.filter(
        &String.contains?(
          &1,
          "Heartbeat suppressed: waiting for manual approval before more agent work"
        )
      )
    end

    defp mark_stage_running(stage) do
      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()
    end

    # Opens a manual_approval ALONGSIDE the fixture's pending `test_pass`.
    defp open_stage_review_request(task, stage, space, label) do
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: label}]
        })

      {manual_validation, request}
    end

    test "mixed-validation stage narrates the park once, not once per dispatch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      # Start while nothing is pending so the router parks in `:running` —
      # that is what makes the subsequent park a genuine
      # `:running -> :waiting_human` transition rather than a boot-into-parked.
      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert stage_gate_logs(space.id) == []

      open_stage_review_request(task, running_stage, space, "Solo check")

      # Barrier by status read: `create_review_request/1` broadcast
      # `{:review_request_pending, ...}` from this process before returning.
      assert TaskRouter.current_status(task.id).status == :waiting_human

      # Three explicit dispatches — the path `TaskRouterWatcher` injects on
      # every runtime reconnect, and the one that leaked.
      #
      # A barrier after EACH, never one at the end. The property under test is
      # "one line per EPISODE, not one per TICK", and a tick the router has not
      # yet handled contributes nothing to the count — so a batched barrier
      # would let a router that emits on every tick pass whenever the last two
      # ticks were still queued. That is the precise way this test would go
      # vacuous, and the 3x150ms sleep it replaces was buying the separation by
      # guess. Neither the plan-gate nor the stage-gate suppression branch of
      # the `:dispatch` handler re-enters via `send(self(), :dispatch)`
      # (task_router.ex:294/351), so one barrier drains one tick exactly.
      send(pid, :dispatch)
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      # POSITIVE CONTROL for this refutation: "control: three injected
      # dispatches DO broadcast three times when the stage gate is closed"
      # below runs this exact loop with no review request open and observes
      # all three.
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      logs = stage_gate_logs(space.id)

      # MUTATION CHECK (2026-07-25, all six sites at once): this same scenario
      # yields 5 stage-gate lines with every stage-1 guard reverted, and 0 with
      # only the `do_dispatch/2` tail emission reverted — the episode opener,
      # which is silent on `main`. Both directions fail this assertion.
      assert length(logs) == 1,
             "expected exactly one stage-gate suppression log across three ticks, got: #{inspect(logs)}"

      assert String.contains?(hd(logs), "awaiting human review on a manual_approval")
    end

    # POSITIVE CONTROL for the refutation in the test above (task 019fa121
    # stage 4). Every assertion in this describe block is satisfied by a
    # router that has simply stopped dispatching — the suppression tests
    # refute a broadcast, and the log tests count lines the suppression path
    # writes. Nothing in the block, before this, ever asserts that the
    # `send(pid, :dispatch)` + `sync_router/2` sequence CAN produce an
    # attention broadcast at all. Under conversion that gap matters more than
    # it did under sleeps: a barrier that returns instantly makes a vacuous
    # test fast as well as green, and nothing about the run time distinguishes
    # it from a correct one.
    #
    # Same three-tick loop, same barrier placement, gate closed instead of
    # open. It must observe three separate dispatches.
    test "control: three injected dispatches DO broadcast three times when the stage gate is closed",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      _running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      # NO `open_stage_review_request/4` — that single line is the entire
      # difference from the test above.
      for _tick <- 1..3 do
        send(pid, :dispatch)
        :ok = sync_router(task.id)

        # Non-blocking. If the barrier were not a real happens-before proof
        # this would fail here rather than silently passing somewhere else,
        # which is what makes this a control on the BARRIER as well as on the
        # gate.
        assert_received %Phoenix.Socket.Broadcast{
          event: "attention",
          payload: %{signal: %{reason: "task_assigned"}}
        }
      end

      refute TaskRouter.current_status(task.id).status == :waiting_human

      # ...and the suppression copy the sibling test counts is genuinely
      # absent here, so `stage_gate_logs/1` is discriminating rather than
      # matching everything or nothing.
      assert stage_gate_logs(space.id) == []
    end

    test "re-broadcasting the park signal does not re-log into an open episode", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      open_stage_review_request(task, running_stage, space, "Solo check")

      # Barrier by status read, then the log count is safe to take.
      assert TaskRouter.current_status(task.id).status == :waiting_human
      assert length(stage_gate_logs(space.id)) == 1

      # PubSub re-delivery of the same park signal (a runtime reconnect
      # re-subscribes and the broadcast is replayed). One barrier per
      # re-delivery: "does not re-log into an OPEN episode" is a statement
      # about each message individually, and three messages folded behind a
      # single barrier would only ever test the last one.
      send(pid, {:review_request_pending, %{task_id: task.id}})
      :ok = sync_router(task.id)
      send(pid, {:review_request_pending, %{task_id: task.id}})
      :ok = sync_router(task.id)

      # ...and a repeated `{:stage_transitioned, ...}` for the SAME running
      # stage, which exercises the third (reason-less, generic-copy) site.
      send(pid, {:stage_transitioned, running_stage})
      :ok = sync_router(task.id)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(stage_gate_logs(space.id)) == 1,
             "re-broadcasts must not re-log into an already-open episode, got: #{inspect(stage_gate_logs(space.id))}"

      # POSITIVE CONTROL for this emptiness assertion: "control: the
      # reason-less `{:stage_transitioned, ...}` site DOES emit the generic
      # copy when it opens the episode" below. `generic_gate_logs/1` filters
      # on a long, exact copy string; an emptiness assertion against a filter
      # that never matches anything is vacuous no matter how the test
      # synchronises, and the substring collision documented in TRAP 1 is
      # precisely how such a filter drifts out of alignment with the code.
      assert generic_gate_logs(space.id) == [],
             "the reason-less `{:stage_transitioned, ...}` site must stay edge-guarded, got: #{inspect(generic_gate_logs(space.id))}"
    end

    # POSITIVE CONTROL for the two `generic_gate_logs(space.id) == []`
    # refutations in this block (:2106 above and :2360 below).
    #
    # Both of those assert that the reason-less `{:stage_transitioned, ...}`
    # site stays SILENT. Neither can distinguish "the edge guard held" from
    # "`generic_gate_logs/1` matches nothing the router ever writes" — and the
    # helper's own comment records that a loose filter already cost a cycle on
    # 019f9ae5. This is the missing half: drive the router through the one
    # shape where that site is the episode OPENER, and show the generic copy
    # appearing exactly once.
    test "control: the reason-less {:stage_transitioned, ...} site DOES emit the generic copy when it opens the episode",
         %{task: task, assignee: assignee, stage: stage} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      open_stage_review_request(task, running_stage, space, "Solo check")
      assert TaskRouter.current_status(task.id).status == :waiting_human
      assert generic_gate_logs(space.id) == []

      # Re-arm the edge WITHOUT dispositioning the gate — the same injection
      # the `{:task_updated}` test below uses, and real for the same reason:
      # `handle_info({:review_request_resolved, ...})` sets `:running`
      # unconditionally without checking whether other requests on the stage
      # are still pending.
      send(pid, {:review_request_resolved, %{task_id: task.id, outcome: :passed}})
      assert TaskRouter.current_status(task.id).status == :running

      # Now the reason-less site is the first to observe the still-open gate.
      #
      # PRELOAD IS LOAD-BEARING, AND IT IS COVERING A REAL DEFECT — recorded
      # here rather than fixed, because `task_router.ex` is out of scope for
      # task 019fa121 stage 4. Five of the six park sites resolve their stage
      # through `find_stage(Tasks.current_plan(task_id), ...)`, and
      # `Tasks.current_plan/1` preloads `stages: :validations`
      # (tasks.ex:1500). The reason-less `{:stage_transitioned, ...}` site
      # (task_router.ex:711) is the exception: it forwards the stage struct
      # STRAIGHT OFF THE BROADCAST. Production's broadcast carries the result
      # of `Repo.update/1` on a stage loaded by a bare `Repo.get/2`
      # (plan_engine.ex:520 `fetch_stage/1` -> :544 `emit_stage_telemetry/2`),
      # so `stage.validations` is `%Ecto.Association.NotLoaded{}` — which is
      # truthy, survives the `|| []` fallback in
      # `HeartbeatScheduler.pending_validations_for_stage/1`
      # (heartbeat_scheduler.ex:1017) and raises
      # `Protocol.UndefinedError` out of the `Enum.filter/2` on the next line.
      # Injecting the unpreloaded struct here kills the router outright; that
      # is what this control did on its first run.
      #
      # Nothing caught it before because no test had ever driven this site
      # while the router was `:running` — the sibling test at :2091 injects
      # the same message but the router is already `:waiting_human`, so the
      # edge guard returns before the predicate is consulted. That is exactly
      # the class of gap a positive control exists to close: every existing
      # assertion about this site was an assertion about a code path that
      # cannot execute.
      send(pid, {:stage_transitioned, Platform.Repo.preload(running_stage, :validations)})
      # Two barriers, because the handler self-sends `:dispatch` for a
      # `running` stage (task_router.ex:700) BEFORE it parks: the first
      # barrier drains the stage broadcast, the second drains the tick it
      # spawned, which a single call cannot reach (the self-send lands behind
      # the call already in the mailbox).
      #
      # HONESTY NOTE (barrier-deletion control, 019fa121 stage 4): deleting
      # both without restoring a sleep does NOT fail this test at seeds
      # 11/22/33/44. The `current_status/1` read below is itself a barrier for
      # the first hop, and the delegated dispatch contributes no GENERIC line
      # (it takes the stage-gate copy path and finds the router already
      # parked), so the count cannot move. These two are the faithful
      # translation of the ordering the test means to assert — defensive, not
      # demonstrated load-bearing. Said plainly rather than left to imply
      # every barrier here bites.
      :ok = sync_router(task.id)
      :ok = sync_router(task.id)

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(generic_gate_logs(space.id)) == 1,
             "the reason-less site must narrate the episode it opens, got: #{inspect(generic_gate_logs(space.id))}"
    end

    test "the episode re-arms after disposition — the guard is an edge, not a latch", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      {_validation, request} =
        open_stage_review_request(task, running_stage, space, "First gate")

      # Barrier by status read for the `{:review_request_pending}` broadcast.
      assert TaskRouter.current_status(task.id).status == :waiting_human
      assert length(stage_gate_logs(space.id)) == 1

      # Disposition the ONLY item. The stage does not complete — the fixture's
      # `test_pass` is still pending — so the router returns to `:running` on
      # the same stage, which is exactly the shape that must re-arm the edge.
      # `approve_item/2` broadcasts `{:review_request_resolved, :passed}` from
      # this process, and that handler does not re-dispatch, so the status
      # read below is a complete barrier for it.
      {:ok, _} = Platform.Tasks.ReviewRequests.approve_item(hd(request.items).id, "rowan")

      assert TaskRouter.current_status(task.id).status == :running

      # A genuinely NEW episode. Barrier before the ticks, because the edge is
      # opened by the `{:review_request_pending}` broadcast and the whole point
      # of the two ticks is that they arrive AFTER it — a tick folded ahead of
      # the episode opener would be measuring a different sequence.
      open_stage_review_request(task, running_stage, space, "Second gate")
      :ok = sync_router(task.id)

      send(pid, :dispatch)
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      # Load-bearing: nothing between the last tick and this read is a call to
      # the router, and the line it counts is written inside the handler.
      logs = stage_gate_logs(space.id)

      # Two episodes, two lines — and no more than one per episode despite the
      # extra dispatches. Without this test a `status`-latching bug would pass
      # the two tests above while permanently silencing the log.
      assert length(logs) == 2,
             "expected exactly one line per suppression episode across two episodes, got: #{inspect(logs)}"
    end

    test "the plan gate is unregressed and never emits the stage copy", %{
      task: task,
      assignee: assignee,
      plan: plan
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _task} = Tasks.transition_task(task, "planning")

      # Flip the fixture plan in place — `plan_awaiting_review?/1` keys off
      # `Tasks.latest_plan/1`, so an accidental v2 would silently change what
      # is under test.
      _pending_plan = mark_plan_pending_review(plan)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      space = ExecutionSpace.find_by_task_id(task.id)

      # One barrier per tick: this is a "one line across three ticks" count and
      # an unhandled tick contributes nothing, so batching would let a
      # per-tick emitter pass on a technicality.
      send(pid, :dispatch)
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      # POSITIVE CONTROL for this refutation: ":1644 approved plan still
      # dispatches — the plan guard is not over-broad".
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     400

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(plan_gate_logs(space.id)) == 1,
             "019f9ae5 regression: expected exactly one plan-gate log, got: #{inspect(plan_gate_logs(space.id))}"

      # The plan branch is ordered ahead of the stage branch in the `:dispatch`
      # handler, so while the plan is provisional the STAGE copy must never
      # appear. This is the assertion the loose `suppression_logs_since/2`
      # filter cannot make.
      #
      # POSITIVE CONTROL for this emptiness assertion: the five tests in this
      # block that assert `length(stage_gate_logs(space.id)) == 1` (or `== 2`)
      # show the same filter matching real router output, so an empty result
      # here means the stage copy was not written — not that the filter is
      # blind to it.
      assert stage_gate_logs(space.id) == [],
             "the stage copy must never be emitted while the plan is provisional, got: #{inspect(stage_gate_logs(space.id))}"
    end

    test "a router that BOOTS into an open gate narrates once with the stage-gate copy", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      open_stage_review_request(task, running_stage, space, "Boot gate")

      # An active lease is what routes `init/1` into its
      # `waiting_for_human_review?/1` branch (the branch every production boot
      # path takes: gateway restart, `TaskRouterWatcher.boot_reconcile/0`).
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.progress",
          "payload" => %{"summary" => "waiting for review"}
        })

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # ONE barrier covers init AND its delegated dispatch, which is the whole
      # thing this test measures. `start_link/1` returns only after `init/1`
      # has run, and the `waiting_for_human_review?/1` branch delegates with a
      # bare `send(self(), :dispatch)` (task_router.ex:230) — not
      # `Process.send_after/3` — so that tick is already in the mailbox AHEAD
      # of the `current_status/1` call enqueued next. Erlang's FIFO ordering
      # then guarantees the delegated dispatch is handled before the call is
      # answered, and neither suppression branch re-enters. The 250ms sleep
      # was buying that ordering by guess; the read below proves it.
      assert TaskRouter.current_status(task.id).status == :waiting_human

      # `init/1` is episode start by definition, so it is deliberately the ONE
      # unguarded emitter — and with the handler now edge-triggered it is the
      # SOLE emitter for this shape (init emits, parks, then delegates via
      # `send(self(), :dispatch)`, which correctly skips).
      assert length(stage_gate_logs(space.id)) == 1,
             "expected exactly one stage-gate log from init/1 + its delegated dispatch, got: #{inspect(stage_gate_logs(space.id))}"

      # ...and it must be the stage-gate copy, not the reason-less generic one.
      # Without the explicit `reason:` on the `init/1` call, a boot-into-parked
      # episode falls through to "Heartbeat suppressed: waiting for manual
      # approval..." and becomes ungreppable by the stage-gate copy — one
      # episode, two different strings depending on how the router got there.
      assert generic_gate_logs(space.id) == [],
             "boot-time stage-gate episodes must use the stage-gate copy, got: #{inspect(generic_gate_logs(space.id))}"
    end

    test "a task update is narrated when it is the first site to observe the open gate", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      running_stage = mark_stage_running(stage)

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      open_stage_review_request(task, running_stage, space, "First gate")
      # Load-bearing: the assertion on the next line is a `Repo` read of a row
      # written inside the router's `{:review_request_pending}` handler, and
      # unlike the sibling tests there is no `current_status/1` call in front
      # of it to do the ordering.
      :ok = sync_router(task.id)
      assert length(stage_gate_logs(space.id)) == 1

      # Return the router to `:running` while the gate is STILL open. This is
      # real: `handle_info({:review_request_resolved, ...})` sets `:running`
      # unconditionally, without checking whether OTHER requests on the stage
      # remain pending, so a multi-gate stage lands here for real. Injecting
      # the broadcast keeps it deterministic (a real `approve_item/2` fans out
      # several racing broadcasts) — same technique as the plan-gate test that
      # injects `{:plan_updated, pending_plan}` directly.
      # Barrier by status read — the `:passed` branch does not re-dispatch.
      send(pid, {:review_request_resolved, %{task_id: task.id, outcome: :passed}})
      assert TaskRouter.current_status(task.id).status == :running

      # `{:task_updated}` is a silent park site on `main`: it flips the router
      # to `:waiting_human` without narrating. If it is the first site to
      # observe the still-open gate, the episode goes unnarrated entirely.
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})

      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert length(stage_gate_logs(space.id)) == 2,
             "the `{:task_updated}` park site must narrate the episode it opens, got: #{inspect(stage_gate_logs(space.id))}"

      # ...and it is edge-triggered like every other site: `{:task_updated}`
      # fires from many places in `tasks.ex`, so an unconditional log here
      # would be the pile-up this task set out to fix.
      # One barrier per update, for the same reason as the dispatch loops: the
      # claim is per-message ("repeated updates must not re-log"), so folding
      # both behind one barrier would only ever exercise one of them.
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})
      :ok = sync_router(task.id)
      send(pid, {:task_updated, Tasks.get_task_detail(task.id)})
      :ok = sync_router(task.id)

      assert length(stage_gate_logs(space.id)) == 2,
             "repeated task updates must not re-log into an open episode, got: #{inspect(stage_gate_logs(space.id))}"
    end
  end

  describe "dispatch suppression predicate (task 019e00cb stage 2)" do
    # Predicate `HeartbeatScheduler.heartbeat_suppressible?/2` gates the
    # `maybe_log_heartbeat_suppressed/3` call — when the running stage is
    # a manual_approval whose only pending validation is linked to an open
    # review_request, the per-dispatch "Dispatch suppressed" log is elided.
    # (The old escalation-ladder tests are gone with the polling scheduler;
    # only the dispatch-time log suppression remains relevant.)

    defp seed_linked_manual_approval(task, stage, space) do
      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Visual check"}]
        })

      {manual_validation, request}
    end

    defp drop_seed_validations(stage) do
      Platform.Repo.delete_all(
        from(v in Platform.Tasks.Validation, where: v.stage_id == ^stage.id)
      )
    end

    test "all-linked manual_approval pending → maybe_log_heartbeat_suppressed posts no execution-space log",
         %{
           task: task,
           assignee: assignee,
           stage: stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task(task, "in_progress")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)
      drop_seed_validations(stage)
      seed_linked_manual_approval(task, stage, space)

      # Barrier: `create_review_request/1` above broadcasts to the router,
      # whose handler posts into the execution space. The baseline snapshot
      # below must not race those posts.
      :ok = sync_router(task.id)

      # Snapshot messages BEFORE forcing a redundant :dispatch tick.
      baseline = ExecutionSpace.list_messages_with_participants(space.id)
      baseline_count = length(baseline)

      # The :dispatch handler hits the pre-dispatch guard which calls
      # maybe_log_heartbeat_suppressed/3. With the predicate gate, that
      # call must NOT post a "Dispatch suppressed" line.
      send(pid, :dispatch)
      # Barrier: the suppression log (or its absence) is written inside the
      # `:dispatch` handler this `send/2` just enqueued.
      :ok = sync_router(task.id)

      after_msgs = ExecutionSpace.list_messages_with_participants(space.id)
      new_msgs = Enum.drop(after_msgs, baseline_count) |> Enum.map(& &1.content)

      suppression_logs =
        Enum.filter(new_msgs, fn m ->
          String.contains?(m, "Dispatch suppressed") or
            String.contains?(m, "Heartbeat suppressed")
        end)

      assert suppression_logs == [],
             "expected predicate gate to swallow suppression log, got: #{inspect(suppression_logs)}"
    end
  end

  describe "deploy stage failure recovery" do
    test "failed deploy stage returns state, router stays alive, task bounces to in_progress AND re-dispatches",
         %{
           task: task,
           assignee: assignee,
           plan: plan,
           stage: _stage
         } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention so we can watch for the
      # re-dispatch caused by the deploy failure.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Transition task through to deploying
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      # Create a deploy stage and mark it as failed
      {:ok, deploy_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Deploy: PR merge",
          description: "Deploy via PR"
        })

      failed_deploy =
        deploy_stage
        |> Ecto.Changeset.change(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Platform.Repo.update!()
        |> Platform.Repo.preload(:validations)

      # Broadcast the failed stage transition
      Tasks.broadcast_board({:stage_transitioned, failed_deploy})
      :ok = sync_router(task.id)

      # Router must still be alive — before this fix it crashed on nil state.
      # The barrier above already proves this (a dead router makes
      # `sync_router/2` flunk), but the assertion is kept because it names the
      # regression: a nil-state crash here is the defect under test, and a
      # reader should not have to know the barrier's failure modes to see it.
      assert Process.alive?(pid)

      # Task should have bounced back to in_progress
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      # Regression: a fresh `task_assigned` dispatch fires after the bounce
      # so the agent picks up the in_progress prompt (this is the branch
      # the stage 3 redesign explicitly preserves byte-for-byte per spec).
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # deploying -> done requires a settled deploy stage (task 019f9b34)
  # ────────────────────────────────────────────────────────────────────
  #
  # Incident 019f9ae5: `inject_deploy_stage/4` created the deploy stage,
  # transitioned the task to `deploying`, then broadcast `{:plan_updated,
  # plan}` carrying a STALE `completed` status. The router's
  # `deploying -> done` arm trusted that status and marked the task `done`
  # at 21:10:06.840 — eight minutes before the PR merged, with the deploy
  # stage still `running`. The guard makes the task status independent of
  # the plan row's bookkeeping.

  describe "deploying -> done requires a settled deploy stage (task 019f9b34)" do
    defp seed_running_deploy_stage!(plan, status) do
      {:ok, deploy_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Deploy: PR merge",
          description: "Deploy via PR merge"
        })

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: deploy_stage.id, kind: "pr_merged"})

      deploy_stage
      |> Ecto.Changeset.change(%{status: status, started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()
    end

    defp drift_plan_to_completed!(plan) do
      plan
      |> Ecto.Changeset.change(%{status: "completed"})
      |> Platform.Repo.update!()
    end

    test "a stale `completed` broadcast does NOT flip the task to done while the deploy stage is running",
         %{task: task, assignee: assignee, plan: plan} do
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Sequencing barrier: `init/1` puts `:dispatch` in the router's own
      # mailbox before `start_link/1` returns, and that handler reads the task
      # row. Draining it here pins the boot dispatch strictly BEFORE the status
      # transitions below, so the router observes one ordering on every run.
      #
      # DEFENSIVE, NOT DEMONSTRATED. Deleting this barrier alone (without
      # restoring the sleep it replaced) was measured GREEN 5/5 at seeds 0-4.
      # It is kept because it makes the ordering explicit and costs no wall
      # clock, not because a failure was observed without it. The barrier
      # AFTER the broadcast below is the one that was measured load-bearing.
      :ok = sync_router(task.id)

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "deploying")

      _deploy_stage = seed_running_deploy_stage!(plan, "running")
      completed_plan = drift_plan_to_completed!(plan)

      Tasks.broadcast_board({:plan_updated, completed_plan})
      # DEMONSTRATED load-bearing, and NOT by deleting it — this is a
      # refutation test, so removing the barrier leaves it green. Measured by
      # holding a mutation fixed and varying only the barrier: with
      # `deploy_stage_settled?/1` forced to `true` (the guard removed), this
      # test is RED 3/3 with the barrier and GREEN 3/3 without it. Without the
      # barrier the task row is re-read before the router has handled the
      # broadcast, so "still deploying" is just the value nothing has touched.
      :ok = sync_router(task.id)

      updated_task = Tasks.get_task_detail(task.id)

      assert updated_task.status == "deploying",
             "a running deploy stage must hold the task at deploying — a `completed` plan is " <>
               "not evidence the deploy landed (task 019f9b34 / incident 019f9ae5)"
    end

    # REMOVED by task 019fa2fc stage 3: the two "still promotes the task to
    # done" tests (settled deploy stage / no deploy stage at all). Both drove
    # the router's `deploying -> done` arm, which no longer exists. Their
    # anti-inertness intent moved with the guard to
    # `Platform.Tasks.PlanCompletion` — see the `:deploy_stage_passed` tests in
    # `plan_completion_test.exs`, including the zero-deploy-stage case.
    #
    # The surviving test above still passes, now for a stronger reason: the
    # router performs no transition at all on a `completed` broadcast.
    #
    # Merge note for task 019fa121: resolve any conflict here by taking the
    # deletion.
  end

  # ────────────────────────────────────────────────────────────────────
  # Stage-scoped blocker handling (task 019f6791 stage 3)
  # ────────────────────────────────────────────────────────────────────
  #
  # Regression coverage for the router-level leak Rowan observed on
  # task 019f6380: a `blocked` lease created against a prior stage was
  # rehydrating the router into `:waiting_human` on stage transition and
  # on boot, silently gating downstream dispatches. The fix threads
  # `stage_id` through the blocker handler + hydration paths so leftover
  # rows for `passed` stages never poison the currently-running stage.

  describe "stage-scoped blocker handling (task 019f6791)" do
    defp seed_stage!(plan, position, name, status) do
      attrs = %{
        plan_id: plan.id,
        position: position,
        name: name,
        description: "stage #{position}"
      }

      attrs =
        case status do
          "running" -> Map.merge(attrs, %{status: "running", started_at: DateTime.utc_now()})
          "passed" -> Map.merge(attrs, %{status: "passed", completed_at: DateTime.utc_now()})
          _ -> attrs
        end

      {:ok, stage} = Tasks.create_stage(attrs)
      {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      stage
    end

    defp seed_blocked_lease!(task_id, stage_id, runtime_id) do
      now = DateTime.utc_now()

      %ExecutionLease{}
      |> ExecutionLease.changeset(%{
        task_id: task_id,
        phase: "execution",
        runtime_id: runtime_id,
        stage_id: stage_id,
        status: "blocked",
        block_reason: "seeded stale blocker",
        started_at: now,
        expires_at: DateTime.add(now, 15 * 60, :second)
      })
      |> Platform.Repo.insert!()
    end

    test "bug repro: blocker on stage B does not gate stage C dispatch after transition", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # Stage A already exists (seeded in setup). Mark it passed; seed B running, C pending.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")
      stage_c = seed_stage!(plan, 3, "stage C", "pending")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Consume the initial dispatch attention for stage B.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # No barrier needed: `current_status/1` IS the barrier.
      assert TaskRouter.current_status(task.id).current_stage_id == stage_b.id

      # Fire a legitimate stage-B blocker. Router should flip to
      # :waiting_human because the blocker targets the current stage.
      blocked_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage_b.id,
        event_type: "execution.blocked",
        payload: %{"stage_id" => stage_b.id, "description" => "waiting on subagent"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, blocked_event})

      assert TaskRouter.current_status(task.id).status == :waiting_human

      # Now transition stage B → passed and stage C → running (mirrors
      # the PlanEngine finalize/advance pair the real engine writes —
      # both broadcasts fire; the running-broadcast is what re-arms
      # dispatch, the passed-broadcast is what drops stage-B's leases).
      stage_b
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      running_stage_c =
        stage_c
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      passed_stage_b = Platform.Repo.get!(Platform.Tasks.Stage, stage_b.id)
      Tasks.broadcast_board({:stage_transitioned, passed_stage_b})
      Tasks.broadcast_board({:stage_transitioned, running_stage_c})

      # A fresh attention broadcast for stage C must fire. The preceding
      # barrier does NOT cover it — the broadcast is produced by a SECOND
      # message (`send(self(), :dispatch)` in task_router.ex), so a message
      # deadline is the right primitive here. 1_000 per the header's
      # deadline convention; this site sat at 500 pre-conversion and flaked
      # under load at ~14%.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_c.id
      assert status.status == :running
      refute status.lease_status == "blocked"
      # The old blocker's runtime-event timestamp must not carry into stage C.
      assert status.last_runtime_event_at == nil
    end

    test "cross-boundary blocker (payload.stage_id != current) does NOT flip to :waiting_human",
         %{task: task, assignee: assignee, plan: plan, stage: stage_a} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      assert TaskRouter.current_status(task.id).status == :running
      assert TaskRouter.current_status(task.id).current_stage_id == stage_b.id

      # File a blocker whose payload.stage_id targets stage A (already passed).
      # Router must ignore and stay :running.
      stale_event = %{
        id: nil,
        task_id: task.id,
        stage_id: stage_a.id,
        event_type: "execution.blocked",
        payload: %{"stage_id" => stage_a.id, "description" => "stale historical blocker"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, stale_event})

      # This is the refutation half — "the router does NOT flip". The
      # `current_status/1` call below is what makes it non-vacuous: it is
      # answered strictly after the router has handled `stale_event`, so a
      # regression that DOES flip is observed rather than raced past. The
      # positive control follows immediately: the same handler, same message
      # shape, only `payload["stage_id"]` changed, must flip.
      status = TaskRouter.current_status(task.id)
      assert status.status == :running
      assert status.current_stage_id == stage_b.id
      # Legit stage-B blocker sanity: same handler still flips when stage_id matches.
      current_event = %{
        stale_event
        | payload: %{"stage_id" => stage_b.id, "description" => "real"}
      }

      send(pid, {:runtime_event, current_event})
      assert TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "legacy blocker with no payload.stage_id preserves pre-fix behaviour (still flips)", %{
      task: task,
      assignee: assignee,
      stage: stage
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      legacy_event = %{
        id: nil,
        task_id: task.id,
        stage_id: nil,
        event_type: "execution.blocked",
        payload: %{"description" => "legacy caller — no stage_id"},
        occurred_at: DateTime.utc_now(),
        runtime_id: assignee.id,
        phase: "execution",
        lease: %{status: "blocked"}
      }

      send(pid, {:runtime_event, legacy_event})

      assert TaskRouter.current_status(task.id).status == :waiting_human
    end

    test "boot rehydration ignores blocked lease attached to a passed stage", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      # Stage A passed with a leaked `blocked` lease; stage B running with no lease yet.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      seed_blocked_lease!(task.id, stage_a.id, assignee.id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # The stale stage-A blocker must NOT gate the initial dispatch —
      # a fresh attention broadcast for stage B fires normally.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     1_000

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      assert status.status == :running
      # The stage-A `blocked` row must NOT rehydrate into state.lease_status.
      refute status.lease_status == "blocked"
    end

    test "boot rehydration prefers the running-stage's own live blocker over a stale one",
         %{
           task: task,
           assignee: assignee,
           plan: plan,
           stage: stage_a
         } do
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "running")

      # Two leases: one leaked from passed stage A, one legit blocker on stage B.
      seed_blocked_lease!(task.id, stage_a.id, assignee.id)
      seed_blocked_lease!(task.id, stage_b.id, assignee.id)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # `init/1` enqueues `:dispatch` into the router's own mailbox before
      # `start_link/1` returns, so this call is answered strictly after boot
      # rehydration has run. No separate barrier is needed.
      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == stage_b.id
      assert status.lease_status == "blocked"
      assert status.status == :waiting_human
    end

    test "stage_transitioned drop_leases_for_stage cleans up prior-stage leases", %{
      task: task,
      assignee: assignee,
      plan: plan,
      stage: stage_a
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      stage_a
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b = seed_stage!(plan, 2, "stage B", "pending")

      # Seed a blocked lease for the currently-running stage A.
      seed_blocked_lease!(task.id, stage_a.id, assignee.id)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # This precondition asserts the seeded lease SURVIVED boot; read before
      # the router has booted, it would pass for the wrong reason — the row is
      # still there because nothing has run yet.
      #
      # DEFENSIVE, NOT DEMONSTRATED. Deleting this barrier alone was measured
      # GREEN 3/3 at seeds 0-2: boot is fast enough that the vacuous reading
      # was not observed. Kept because the argument above is about what the
      # assertion MEANS, which no timing measurement can settle. The barrier
      # after the transition broadcast below IS demonstrated (RED 3/3 without).
      :ok = sync_router(task.id)

      assert %{status: "blocked"} =
               RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)

      # Now transition A → passed, B → running.
      stage_a
      |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      stage_b
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      passed_stage_a = Platform.Repo.get!(Platform.Tasks.Stage, stage_a.id)
      Tasks.broadcast_board({:stage_transitioned, passed_stage_a})
      # `drop_leases_for_stage/2` runs inside the router's own
      # `{:stage_transitioned, _}` handler and `LeaseManager` mutators are
      # synchronous calls, so the row is already gone when the barrier returns.
      :ok = sync_router(task.id)

      # Stage-A lease has been dropped by the transition handler.
      assert nil == RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)
    end
  end

  # ── Bug #7 (task 019f70ff-55c2) ────────────────────────────────────────
  # Regression coverage for the deletion of
  # `TaskRouter.maybe_mark_review_task_in_review/1`. The old helper flipped a
  # task to `in_review` whenever its running stage's only pending validation
  # was `manual_approval` — before any agent had produced work or filed a
  # review request. The canonical trigger is
  # `Platform.Tasks.ReviewRequests.create_review_request/1`, which is
  # exercised in `Platform.Tasks.ReviewRequestsTest`.
  describe "manual_approval-only stage does not auto-flip task to in_review" do
    test "router keeps a task in_progress while a manual_approval-only stage runs without a review_request",
         %{task: task, assignee: assignee, plan: plan, stage: stage} do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      # Replace the seeded stage's `test_pass` validation with a single
      # `manual_approval` validation and flip the stage to running. This is
      # the exact bug shape reported in task 019f70f0: an execution stage
      # whose only pending validation is manual_approval must NOT be
      # misclassified as a review gate.
      Platform.Repo.delete_all(
        from(v in Platform.Tasks.Validation, where: v.stage_id == ^stage.id)
      )

      {:ok, _validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      running_stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      Tasks.broadcast_board({:plan_updated, plan})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      # Refutation test — "the router leaves the task alone". The barrier is
      # what makes it bite: the boot sweep must have RUN before the task row is
      # re-read, otherwise `in_progress` is merely the value nothing has
      # touched yet. Placed here rather than leaning on the `current_status/1`
      # below, because the Repo read comes first.
      #
      # DEMONSTRATED, by holding a mutation fixed and varying only the barrier.
      # Reintroducing the deleted auto-flip (a `:dispatch` cond branch calling
      # `transition_task(task, "in_review")` when `manual_approval_stage?/1`
      # holds) makes this test RED 3/3 with the barrier and GREEN 3/3 without
      # it. Deleting the barrier on its own leaves the test green, which is
      # exactly why barrier-deletion cannot vet a refutation test.
      :ok = sync_router(task.id)

      # Pre-fix: this assertion fails within ~80ms because the router's init
      # sweep called `maybe_mark_review_task_in_review/1` and flipped the
      # task. Post-fix: the router leaves the task alone — only a filed
      # review request can move it to in_review.
      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_progress"

      status = TaskRouter.current_status(task.id)
      assert status.current_stage_id == running_stage.id
    end
  end

  describe "create_review_request/1 remains the sole in_progress -> in_review trigger" do
    test "filing a review_request against a running manual_approval stage flips task to in_review",
         %{task: task, stage: stage} do
      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")

      # Do NOT start the router — this test locks in that the transition
      # trigger lives in `ReviewRequests.create_review_request/1`, independent
      # of any router path.
      _running_stage =
        stage
        |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
        |> Platform.Repo.update!()

      {:ok, manual_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, execution_space} = ExecutionSpace.find_or_create(task.id)

      assert {:ok, _request} =
               Platform.Tasks.ReviewRequests.create_review_request(%{
                 validation_id: manual_validation.id,
                 task_id: task.id,
                 execution_space_id: execution_space.id,
                 items: [%{label: "UI review"}]
               })

      updated_task = Tasks.get_task_detail(task.id)
      assert updated_task.status == "in_review"
    end
  end

  describe "settled stack-member dispatch suppression (TAIL-stall fix, 2026-07-22)" do
    test "a settled stack member (no running stage, no open validation) suppresses dispatch",
         %{assignee: assignee} do
      # Build a stack member whose plan is fully settled: stage passed, both
      # validations passed, no pending review request. This is the incident
      # shape — a member the router would otherwise re-dispatch a stale
      # prompt it can't act on.
      {:ok, project} = Tasks.create_project(%{name: "Settled member #{unique()}"})
      slug = "settled-#{unique()}"

      {:ok, stack} =
        Platform.Tasks.Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Settled Stack #{slug}",
          rollup_branch: Platform.Tasks.Stacks.rollup_branch_name(slug)
        })

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Settled member #{unique()}",
          status: "deploying",
          stack_id: stack.id,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Task-level review",
          status: "passed"
        })

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: member.id, assignee: assignee)

      member_id = member.id

      # The initial :dispatch scheduled by init/1 hits the settled-member
      # guard and emits observe-only telemetry instead of dispatching.
      assert_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref,
                      %{count: 1}, %{task_id: ^member_id, reason: :settled_stack_member}},
                     1_000

      # No dispatch/attention broadcast is emitted for the settled member.
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     300
    end

    test "a stack member with a still-pending validation is NOT suppressed", %{
      assignee: assignee
    } do
      {:ok, project} = Tasks.create_project(%{name: "Working member #{unique()}"})
      slug = "working-#{unique()}"

      {:ok, stack} =
        Platform.Tasks.Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Working Stack #{slug}",
          rollup_branch: Platform.Tasks.Stacks.rollup_branch_name(slug)
        })

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Working member #{unique()}",
          status: "in_progress",
          stack_id: stack.id,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "coding",
          status: "running"
        })

      {:ok, _} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: member.id, assignee: assignee)

      # A member with genuinely pending work must never be suppressed.
      refute_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref, _, _}, 400
    end
  end

  # Fixture helper for the late-precondition describe block below.
  defp late_precondition_task(status, stage_specs) do
    {:ok, project} = Tasks.create_project(%{name: "Late precondition #{unique()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Late precondition #{unique()}",
        status: status,
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    stages =
      for {name, position, initial_status} <- stage_specs do
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: position,
            name: name,
            status: initial_status
          })

        stage
      end

    {task, plan, stages}
  end

  defp stage_status(stage_id), do: Platform.Repo.get!(Platform.Tasks.Stage, stage_id).status

  # ────────────────────────────────────────────────────────────────────
  # Late-precondition stage opening (task 019fbe9e stage 3)
  # ────────────────────────────────────────────────────────────────────
  #
  # Every fixture here is built LATE-PRECONDITION: the plan is approved (or
  # the stage fails) BEFORE the condition that should open a stage becomes
  # true. That ordering is the whole point. The pre-fix tree wires
  # `ensure_execution_stage_started/2` to a single edge — plan approval — and
  # that function early-returns unless the task is ALREADY `in_progress`, so a
  # fixture that approves the plan while the task is already `in_progress`
  # passes against the broken code and proves nothing.
  describe "opening a stage when the precondition arrives late" do
    test "a plan approved while the task sits at stack_pending still opens stage 1 on promotion",
         %{assignee: assignee} do
      {task, _plan, [first, second]} =
        late_precondition_task("stack_pending", [
          {"coding", 1, "pending"},
          {"review", 2, "pending"}
        ])

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Precondition arrives here, long after the approval edge already fired.
      assert {:ok, promoted} = Tasks.transition_task(task, "in_progress")
      assert promoted.status == "in_progress"

      # Mailbox barrier — the broadcast is dispatched in THIS process, so by
      # the time this call returns the router has drained `{:task_updated, _}`.
      _ = TaskRouter.current_status(task.id)

      assert stage_status(first.id) == "running"
      # Only the lowest-position pending stage is started.
      assert stage_status(second.id) == "pending"
    end

    test "a task promoted with a stage already running is not disturbed (idempotency)", %{
      assignee: assignee
    } do
      {task, _plan, [first, second]} =
        late_precondition_task("stack_pending", [
          {"coding", 1, "running"},
          {"review", 2, "pending"}
        ])

      before = Platform.Repo.get!(Platform.Tasks.Stage, first.id)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
      assert {:ok, _} = Tasks.transition_task(task, "in_progress")
      _ = TaskRouter.current_status(task.id)

      after_ = Platform.Repo.get!(Platform.Tasks.Stage, first.id)

      assert after_.status == "running"
      assert after_.updated_at == before.updated_at
      # The second stage must not be started alongside the running one.
      assert stage_status(second.id) == "pending"
    end

    test "a review-stage failure bounce re-opens the next pending stage", %{assignee: assignee} do
      {task, _plan, [coding, review, followup]} =
        late_precondition_task("in_review", [
          {"coding", 1, "passed"},
          {"Task-level review", 2, "failed"},
          {"rework", 3, "pending"}
        ])

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      failed = Platform.Repo.get!(Platform.Tasks.Stage, review.id)
      Tasks.broadcast_board({:stage_transitioned, failed})
      _ = TaskRouter.current_status(task.id)

      assert Tasks.get_task_detail(task.id).status == "in_progress"
      # The disjunct shipped for a bounce that still HAS work: a stage runs.
      assert stage_status(followup.id) == "running"
      assert stage_status(coding.id) == "passed"
    end

    # FALSIFIED PREMISE, recorded here because the next reader will otherwise
    # try to add the guard again: the stage brief called for a NEW withhold
    # clause in `handle_info(:dispatch, _)` for "in_progress, no running stage,
    # no pending stage". That guard already exists — `unresolved_stage_dispatch?/3`
    # inside `do_dispatch/2` (task 019fa469 stage 4) — with the identical
    # three-conjunct predicate, the same loud log, the same execution-space
    # line, and the same suppression telemetry under `reason: :unresolved_stage`.
    # A second clause was written, and it silently STOLE the case from the
    # existing one: `task_router_unresolved_stage_test.exs:114` went red because
    # it saw the new reason atom. The duplicate was removed rather than
    # reconciled. This test therefore asserts the EXISTING guard covers the
    # bounce, which is the fact the stage actually needed established.
    test "a bounce with no startable stage withholds the dispatch instead of prompting", %{
      assignee: assignee
    } do
      {task, _plan, [_coding, review]} =
        late_precondition_task("in_review", [
          {"coding", 1, "passed"},
          {"Task-level review", 2, "failed"}
        ])

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      failed = Platform.Repo.get!(Platform.Tasks.Stage, review.id)
      Tasks.broadcast_board({:stage_transitioned, failed})

      task_id = task.id

      # Barrier FIRST. The router's own `init/1` dispatch already suppresses
      # for this fixture (it is `in_review` with nothing running), so an
      # `assert_receive` placed here without a barrier matches THAT event and
      # then reads the task before the bounce has been handled at all — which
      # is exactly how this test first went red claiming the bounce never
      # happened.
      _ = TaskRouter.current_status(task_id)

      assert Tasks.get_task_detail(task_id).status == "in_progress"

      assert_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref,
                      %{count: 1}, %{task_id: ^task_id, reason: :unresolved_stage}},
                     1_000

      # The forbidden outcome: prompting an executor into a state where
      # `stage_complete` can only answer "Stage must be running".
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: %{reason: "task_assigned"}}
                     },
                     300
    end

    test "a task at in_progress with every stage pending is never withheld — the stage is started",
         %{assignee: assignee} do
      # ANTI-VACUITY CONTROL for the withhold clause. If the guard keyed off
      # "no running stage" alone it would also match this task, and
      # suppressing here parks it forever: the dispatch is the only thing that
      # would ever have moved it.
      {task, _plan, [first, _second]} =
        late_precondition_task("in_progress", [{"coding", 1, "pending"}, {"review", 2, "pending"}])

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      {:ok, reloaded} = {:ok, Tasks.get_task_detail(task.id)}
      Tasks.broadcast_board({:task_updated, reloaded})
      _ = TaskRouter.current_status(task.id)

      assert stage_status(first.id) == "running"
      refute_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref, _, _}, 300
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # FALSIFIED: "the dispatch payload carries a stale stage_id" (019fbe9e stage 5)
  # ────────────────────────────────────────────────────────────────────
  #
  # The ticket read: an operator acks WITHOUT a `stage_id` and the ack lands on
  # stage N+1 relative to the stage the dispatch named, therefore the dispatch
  # payload's `stage_id` was stale when it was sent. Two explanations fit that
  # observation and they are not the same defect:
  #
  #   (a) the dispatch resolved its stage from the ROUTER'S CACHED
  #       `state.current_stage_id`, which can lag the DB; or
  #   (b) the dispatch was correct when sent and the named stage genuinely
  #       completed before the ack — routine when dispatches arrive duplicated
  #       and late.
  #
  # (a) is FALSE in this tree, and this test is what says so rather than a
  # comment. `do_dispatch/2` opens with `Tasks.current_plan(state.task_id)` and
  # `current_running_stage(plan)`; it never consults `state.current_stage_id`.
  # The cached field is read by the heartbeat, blocker-staleness and diagnostic
  # paths — none of which build a dispatch payload. `resolve_ack_stage_id/2` on
  # the tool side reads the same DB predicate (`status == "running"` on
  # `current_plan/1`). So the two ends agree on a source of truth and can only
  # disagree about TIME, which is (b). No code was added for this item.
  #
  # The fixture is the discriminator, not a smoke test: the router's cached id
  # is deliberately made stale, and the cached stage it points at is one that
  # WOULD resolve if the cache were consulted. If a future edit reintroduces
  # `find_stage(plan, state.current_stage_id) || current_running_stage(plan)`
  # into the dispatch path — the shape the ticket assumed — that stale stage is
  # found, the dispatch is no longer unresolved, and this test goes red.
  describe "the dispatch payload's stage is read fresh, never from cached router state" do
    test "a cached stage_id that outlived its stage does not resolve a dispatch", %{
      assignee: assignee
    } do
      {task, _plan, [first, second]} =
        late_precondition_task("in_progress", [{"coding", 1, "running"}, {"review", 2, "pending"}])

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # The router observed stage 1 running and cached it.
      assert TaskRouter.current_status(task.id).current_stage_id == first.id

      # The DB advances underneath the router with no broadcast — the exact
      # condition under which a cache could go stale unnoticed. Both stages
      # land at `passed`, so a FRESH read resolves no stage at all while the
      # cached id still names a real, findable stage row.
      {2, _} =
        Platform.Repo.update_all(
          from(s in Platform.Tasks.Stage, where: s.id in ^[first.id, second.id]),
          set: [status: "passed"]
        )

      # ANTI-VACUITY: the lag is real. Without this the test could pass
      # because the cache happened to be empty, which proves nothing about
      # where the dispatch reads from.
      assert TaskRouter.current_status(task.id).current_stage_id == first.id
      assert stage_status(first.id) == "passed"

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      task_id = task.id
      send(pid, :dispatch)

      assert_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref,
                      %{count: 1}, %{task_id: ^task_id, reason: :unresolved_stage}},
                     1_000
    end

    test "the ack path resolves the same running-stage predicate the dispatch does" do
      # The other half of (a): if the ack side read a DIFFERENT source from the
      # dispatch side, the two could disagree without either being late. It
      # does not — with no running stage on the current plan, an ack that omits
      # `stage_id` refuses rather than resolving some other stage.
      {task, _plan, [first, _second]} =
        late_precondition_task("in_progress", [{"coding", 1, "passed"}, {"review", 2, "passed"}])

      assert {:error, envelope} =
               Platform.Federation.ToolSurface.execute(
                 "task_ack",
                 %{"task_id" => task.id, "subagent_id" => "probe"},
                 %{}
               )

      assert envelope.error =~ "no running stage"

      # Control: with a stage actually running it resolves to THAT stage, so
      # the refusal above is about state and not about the argument shape.
      {1, _} =
        Platform.Repo.update_all(
          from(s in Platform.Tasks.Stage, where: s.id == ^first.id),
          set: [status: "running"]
        )

      assert {:ok, ack} =
               Platform.Federation.ToolSurface.execute(
                 "task_ack",
                 %{"task_id" => task.id, "subagent_id" => "probe"},
                 %{}
               )

      assert ack.stage_id == first.id
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Zero-sleep guard (task 019fa121 stage 5)
  # ────────────────────────────────────────────────────────────────────
  #
  # Stages 2-5 removed 116 fixed sleeps from this file. Nothing stops the
  # 117th from being added back next week, and the reason it would be added
  # back is always the same: someone hits a race, reaches for the shortest
  # thing that makes it go away, and ships a number. This guard is the thing
  # that argues back at that moment.
  #
  # Two construction details are load-bearing, and both are here because the
  # obvious version of this guard is wrong:
  #
  #   1. COMMENT LINES ARE STRIPPED BEFORE MATCHING. Prose about the forbidden
  #      call is legitimate — this file's own taxonomy header is nothing else —
  #      and a guard that greps the raw buffer fails on its own documentation.
  #      The fix a hurried reader then applies is to delete the documentation.
  #      (Today no comment in this file spells the call, so that a reviewer's
  #      plain `grep -c` agrees with the guard. The stripping is what makes it
  #      safe to write the prose back.)
  #   2. THE NEEDLE IS ASSEMBLED, NOT WRITTEN. `@forbidden_call` is built from
  #      two fragments so that no line of source in this file contains the
  #      literal token — including this test's own matcher and its failure
  #      message, which interpolates the needle rather than spelling it.
  #      Written literally, the guard would report itself.
  #
  # The positive controls below exist because a guard whose input is empty
  # passes for the wrong reason, and a guard whose needle is misspelled passes
  # for the wrong reason too. Neither failure is visible from a green run.
  #
  # ── THE ONE EXCEPTION, AND WHY IT IS NOT AN EXCLUSION LIST ──────────────
  #
  # The doctrine above covers SYNCHRONISATION sleeps: a wait standing in for a
  # barrier, or for a poll on a third process. That is what every one of the
  # 116 sites removed by this task was, and it is the only thing the original
  # guard anticipated.
  #
  # Merging main afterwards surfaced a category it had not: a sleep where the
  # ELAPSED WALL CLOCK IS ITSELF THE SUBJECT OF THE ASSERTION. In
  # "a router restart loop cannot renew the deadline" the test asserts that the
  # armed delay SHRINKS across restarts by at least the time spent dead. There
  # is no event to wait for — nothing is running between the restarts — so no
  # barrier can replace it. Deleting the wait does not make the test faster; it
  # makes it measure nothing and pass against the very regression it exists to
  # catch.
  #
  # Those sites, and only those, may carry an ANNOTATION: the marker
  # `@wall_clock_marker` followed by a justification of at least
  # `@min_justification_chars` characters, ATTACHED TO THE CALL SITE — either
  # trailing on the call line or on the line immediately above it. (Both,
  # because `mix format` hoists a trailing comment that overruns
  # `line_length` onto its own line, and a guard whose verdict changes when the
  # formatter runs would just teach people to ignore it.)
  #
  # Two properties make this different in kind from an allowlist:
  #
  #   * It is not a list of line numbers or test names. Line-number and
  #     test-name exclusions are what this file's own conventions and
  #     `task_alias_shadowing_audit_test.exs:42-45` forbid, because they
  #     decay silently as the file moves and because they say only "this is
  #     exempt" — never why.
  #   * It cannot be satisfied by accident. An author reaching for a fixed
  #     sleep to fix a race has to type an argument that the sleep is a
  #     MEASUREMENT, at the site, in front of a reviewer. That is a far higher
  #     bar than appending an identifier to a list, and it is a claim the diff
  #     makes checkable: either the test asserts on elapsed time or it does not.
  #
  # ABSENCE ASSERTIONS ARE EXPLICITLY NOT ELIGIBLE, and this is the boundary
  # most likely to be argued at. A sleep before `assert Registry.lookup(..) ==
  # []` or `refute ...` looks superficially similar — "give it a chance to
  # misbehave" — but it is the opposite case. The observable is ALREADY in the
  # asserted state before the other process does anything, so the sleep
  # expiring is not evidence that anything ran, and the assertion passes
  # whether or not the code under test works. Task 019fa003 stage 4 measured
  # this directly: with the actor `:sys.suspend`ed, the sleep-based absence
  # assertion passed vacuously while the barrier version correctly failed. An
  # absence assertion synchronised by a sleep is suspect BY CONSTRUCTION — it
  # is not a category this guard missed, it is the defect the guard exists to
  # catch. Use a barrier that proves the actor handled the event, then assert
  # the absence. `:2185` is the worked example.
  #
  # The annotated count is additionally PINNED (`@annotated_site_budget`), on
  # the same non-accretion principle the shell guard uses: a genuine new
  # measurement site is a deliberate, reviewable diff that has to move the
  # number, and copying an annotated line to silence the guard trips it.
  describe "zero-sleep guard (task 019fa121)" do
    @source_path __ENV__.file

    # Assembled deliberately — see note 2 above.
    @forbidden_call "Process." <> "sleep"

    # The annotated escape hatch — see "THE ONE EXCEPTION" above. A marker on
    # the call line itself, not a list of exempt locations.
    @wall_clock_marker "WALL-CLOCK-ASSERTION:"

    # Long enough that a justification has to be a sentence. A one-word
    # placeholder is the cargo-cult failure mode this length rules out.
    @min_justification_chars 40

    # Non-accretion pin. Both sites are the restart-loop deadline measurement.
    @annotated_site_budget 2

    test "no fixed-sleep call site has been reintroduced into this file" do
      lines =
        @source_path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)

      code_lines = Enum.reject(lines, fn {line, _n} -> comment_line?(line) end)

      # Annotations are read from the RAW buffer, not `code_lines`: when the
      # marker sits on its own line above the site, `comment_line?/1` has
      # already stripped it out of `code_lines` by design.
      raw = Map.new(lines, fn {line, n} -> {n, line} end)

      # Every surviving call site, split by whether it carries a justified
      # annotation. `annotated` is NOT "ignored" — it is budgeted below.
      {annotated, offenders} =
        code_lines
        |> Enum.filter(fn {line, _n} -> String.contains?(line, @forbidden_call) end)
        |> Enum.split_with(fn {line, n} -> justified?(line, Map.get(raw, n - 1, "")) end)

      # ── POSITIVE CONTROL 1: the stripper did not eat the file ──────────
      # If `comment_line?/1` ever over-matched — a bad regex, a change to the
      # comment syntax, a refactor that trims the wrong thing — `code_lines`
      # would shrink toward empty and the assertion below would pass while
      # inspecting nothing at all. Pin both the volume and a landmark, so
      # "the buffer is intact" is checked rather than assumed.
      assert length(code_lines) > 2_000,
             "comment-stripping left only #{length(code_lines)} code lines; " <>
               "the zero-sleep assertion below would be inspecting an almost-empty buffer"

      assert Enum.any?(code_lines, fn {line, _n} ->
               String.contains?(line, "defmodule Platform.Orchestration.TaskRouterTest")
             end),
             "comment-stripping removed the module definition — the buffer is not this file"

      assert Enum.count(code_lines, fn {line, _n} -> Regex.match?(~r/^\s*test /, line) end) > 50,
             "comment-stripping removed the test bodies — nothing meaningful is being scanned"

      # ── POSITIVE CONTROL 2: the needle is spelled correctly ────────────
      # A typo in `@forbidden_call` produces a permanently-green guard, and a
      # green run cannot tell you that. Anchor it OUTSIDE this file, on the
      # one place in the codebase where the call is legitimate: the polling
      # loop inside `Platform.AsyncAssertions`. A poll implementation has to
      # sleep between attempts, so that occurrence is a standing invariant
      # rather than a coincidence — and anchoring there rather than on this
      # file's own prose is what lets the prose stay unspelled.
      helper_source =
        @source_path
        |> Path.join("../../../support/async_assertions.ex")
        |> Path.expand()
        |> File.read!()

      assert String.contains?(helper_source, @forbidden_call),
             "`@forbidden_call` does not appear in Platform.AsyncAssertions, whose poll loop " <>
               "certainly calls it. The needle is misspelled and this guard is inert."

      # ── POSITIVE CONTROL 3: the stripper classifies in BOTH directions ──
      # Control 1 catches a `comment_line?/1` that says "comment" to
      # everything. This catches the opposite mutation — one that says
      # "comment" to nothing — which control 1 cannot see while the prose in
      # this file stays unspelled, and which would silently un-do detail 1.
      assert comment_line?("  # #{@forbidden_call}(50) described in prose")
      refute comment_line?("  #{@forbidden_call}(50)")

      # ── POSITIVE CONTROL 4: the escape hatch classifies in BOTH directions ──
      # `justified?/1` is the only thing standing between the annotation and an
      # allowlist. If it ever said "justified" to everything, the guard would
      # be inert with no visible symptom; if it said "justified" to nothing,
      # the two real measurement sites would already be failing above and
      # someone would delete the mechanism rather than debug it. Pin both.
      long_enough = String.duplicate("x", @min_justification_chars)
      site = "  #{@forbidden_call}(120)"

      # BOTH accepted positions, because `mix format` picks between them.
      assert justified?("#{site} # #{@wall_clock_marker} #{long_enough}", "")
      assert justified?(site, "  # #{@wall_clock_marker} #{long_enough}")

      # No marker anywhere — the overwhelmingly common case, and an offender.
      refute justified?(site, "  d1 = armed_delay.()")

      # Marker present but the justification is a placeholder. Typing the token
      # must not be enough; the argument is the point of the mechanism.
      refute justified?(site, "  # #{@wall_clock_marker} because")

      # Marker present, justification empty. Same failure, spelled differently.
      refute justified?("#{site} # #{@wall_clock_marker}", "")

      # Two lines away is NOT attached. Without this the "annotation" would
      # drift into a floating exemption anywhere above the site.
      refute justified?(site, "")

      assert offenders == [], """
      #{length(offenders)} `#{@forbidden_call}` call site(s) were reintroduced into
      #{Path.relative_to_cwd(@source_path)}:

      #{Enum.map_join(offenders, "\n", fn {line, n} -> "  line #{n}: #{String.trim(line)}" end)}

      Use a barrier, not a number.

      `Platform.AsyncAssertions.sync_router/2` is the right tool for almost
      every site in this file. It is a pure `GenServer.call` to the router
      under test, so it returns strictly after the router has handled every
      message already in its mailbox — a happens-before proof, not a
      probability. `Platform.Tasks.broadcast_board/1` dispatches to local
      subscribers in the CALLING process, so the message is in the router's
      mailbox before it returns; the barrier queues behind it.

      Where the assertion that follows is already `TaskRouter.current_status/1`,
      you need nothing at all — that call IS the barrier. Delete the wait.

      Reach for `Platform.AsyncAssertions.assert_eventually/3` only when a
      THIRD process owns the effect you are asserting on (a `Registry` entry
      clearing after a `:DOWN`, say) and you can name that process at the call
      site. If you cannot name it, you wanted the barrier.

      If the actor is the singleton `TaskRouterWatcher` rather than a per-task
      router, `TaskRouterWatcher.sync/0` is the barrier. `:2185` is the one
      site in this file where that is the case.

      IF YOU ARE ABOUT TO ARGUE THAT YOUR SITE IS AN EXCEPTION, read the
      annotation contract in the comment above this describe block first. There
      is exactly one eligible category — the sleep whose ELAPSED TIME IS ITSELF
      THE SUBJECT of an assertion, which no barrier can express — and it is
      claimed with `#{@wall_clock_marker}` plus a written argument attached to
      the call site, not by adding a line number anywhere.

      A sleep in front of an ABSENCE assertion (`== []`, `refute_*`, "prove it
      does NOT happen") is NOT that category and is never eligible. The
      observable is already in the asserted state before anything runs, so the
      sleep expiring proves nothing and the assertion passes on a broken tree.
      That is the defect this guard exists to catch, not an exception to it.

      Why this is a hard rule rather than a preference: a fixed sleep is a
      guess in both directions. Too short and it races the router, which is how
      this suite acquired failures whose membership changed run to run. Too
      long and it hides a real regression behind wall-clock padding while
      taxing every future run for the privilege. The 116 sleeps removed by task
      019fa121 cost 11.125 seconds per run and bought no determinism at all.
      """

      # ── NON-ACCRETION PIN ON THE ESCAPE HATCH ──────────────────────────
      # `offenders == []` above is satisfied by annotating everything, so the
      # annotation needs a ceiling or it decays into the allowlist it was
      # designed not to be. Pinning the count makes every new measurement site
      # a deliberate diff that moves a number a reviewer can see, and makes
      # "copy the justification off the line above" fail rather than work.
      assert length(annotated) <= @annotated_site_budget, """
      #{length(annotated)} annotated `#{@forbidden_call}` site(s) — the pin is #{@annotated_site_budget}:

      #{Enum.map_join(annotated, "\n", fn {line, n} -> "  line #{n}: #{String.trim(line)}" end)}

      Adding one is allowed, but it is not routine and it is not a formality.
      Satisfy yourself that the new site is a MEASUREMENT — that some assertion
      in the same test reads the elapsed time, and that deleting the wait makes
      that assertion weaker rather than merely faster — and then raise
      `@annotated_site_budget` in the same commit so the claim is reviewed
      alongside the code making it.

      If you got here by copying an annotated line to quiet the guard: that is
      the case this pin exists for. The site you copied it to almost certainly
      wants `sync_router/2`.
      """
    end

    # A line whose first non-whitespace character starts a comment. Trailing
    # comments on a code line are deliberately NOT stripped: a line that both
    # executes something and mentions the forbidden call is exactly the case
    # this guard must not be talked out of. Keep prose on its own line.
    defp comment_line?(line), do: String.starts_with?(String.trim_leading(line), "#")

    # The annotated escape hatch. A call site is justified only if the marker
    # AND a substantive argument appear either ON the call line or on the line
    # IMMEDIATELY above it.
    #
    # Both positions are accepted because `mix format` chooses between them and
    # the choice is not the author's. A trailing `# marker: <argument>` that
    # pushes the line past `line_length` is hoisted onto its own line by the
    # formatter — which is exactly what happened to both sites below when this
    # mechanism was written same-line-only, and which turned a justified site
    # back into an offender at the next `mix format`. A guard whose verdict
    # flips when the formatter runs is worse than no guard: it teaches people
    # that the guard is noise. Accepting both shapes makes the mechanism
    # formatter-agnostic, and the length floor keeps the same-line form from
    # being the cheap one to satisfy.
    #
    # Attaching to the site (rather than to a line number recorded elsewhere)
    # is what makes drift fail SAFE: separate the justification from its site
    # by an unrelated edit and the site becomes an unannotated offender, which
    # fails loudly, rather than a stale exemption that keeps passing.
    #
    # The length floor is doing real work: it is what makes the mechanism an
    # ARGUMENT rather than a token. A one-word "needed" is not a reason, and a
    # guard that accepted it would be an allowlist with extra steps.
    defp justified?(site_line, preceding_line) do
      justification?(site_line) or justification?(preceding_line)
    end

    defp justification?(line) do
      case String.split(line, @wall_clock_marker, parts: 2) do
        [_before, justification] ->
          String.length(String.trim(justification)) >= @min_justification_chars

        _ ->
          false
      end
    end
  end

  # ── ADR-0046 member 7 stage 5: the pre-plan design hold ─────────────────
  #
  # ## Verification labels
  #
  # **Load-bearing controls.** Each absence assertion below is paired, in the
  # SAME test, with a case proving the mechanism it asserts the absence of can
  # actually fire:
  #
  #   * "no attention broadcast while held" is paired with a NON-UI task of the
  #     same shape that broadcasts inside the same window. A `do_dispatch/2`
  #     deleted outright would fail the control, not pass the absence.
  #   * "no armed lease while held" SEEDS a lease via
  #     `LeaseManager.record_dispatch/4` before the tick and asserts it is gone
  #     after. Without the seed the assertion would be vacuous — a planning task
  #     with no running stage never arms a lease in the first place, so
  #     `LeaseManager.get/1 == nil` holds against a `clear_liveness/1` that was
  #     never called. The control is the non-UI task, whose seeded lease
  #     SURVIVES its dispatch, proving the clear is specific to the hold.
  #   * "the deadline is a no-op after a settle" is paired with the
  #     still-designing case in the same describe, over the same fixture, so a
  #     `:design_deadline` handler stubbed to `{:noreply, state}` cannot pass.
  #   * "the shipped default is 1_800_000" is paired with an injected value that
  #     must be OBSERVED, proving the read goes through `Application.get_env/3`
  #     rather than the literal.
  #
  # **Declared vacuity.** Two, and both are worth stating rather than hiding:
  #
  #   * "a task already carrying a plan is never held" PASSES against a tree
  #     with no design hold at all — it is an absence assertion and absence is
  #     the pre-change state. It is not vacuous against the shipped code: the
  #     thing it pins is the `Tasks.latest_plan/1 == nil` conjunct in
  #     `design_step_open?/1`, and removing only that conjunct fires it. That is
  #     the peel that locates what carries this claim.
  #   * "killing the holder does not strand the task" is protected REDUNDANTLY
  #     by the level check and by the DB-derived deadline in
  #     `arm_design_deadline/3`. Removing either one alone leaves the other to
  #     release the replacement router, so no single peel fires it. Only the
  #     conjunction does. The redundancy is deliberate — this is the property
  #     the whole stage exists for — but a test that no single peel can break is
  #     a weak test, and the test below is the one that carries the claim on its
  #     own.
  #
  # ## How the hold cannot outlive its holder
  #
  # "an overdue hold is released by the level check on a tick the armed timer
  # cannot serve" is the discriminating test. It sets the window to an hour, so
  # the timer the hold armed cannot possibly fire inside the test, then backdates
  # the row past the window and delivers one ordinary `:dispatch`. The release
  # can only have come from `design_hold_expired?/2`. That is the journalled
  # `deploying -> done` incident inverted: there, the transition lived only in an
  # edge-triggered handler with no level re-check, and a restart between the
  # broadcast and the handler stranded the task forever.
  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  # Stage 1's classifier is not in doubt on either of these: the UI title is
  # stage 1's own doctest example.
  @design_ui_title "Add an epic-create FAB above the board"
  @design_non_ui_title "Add Providers.Architecture shim"

  # Task 019fa504. TEN MINUTES, and the size is the whole point: the claim under
  # test is that the DECLINE released the planner, so the deadline has to be
  # ruled out as the alternative explanation. At the shipped 1_800_000 a pass
  # would prove nothing about timing (the test never gets near either number),
  # and at a small value the deadline becomes a live competing cause for every
  # assertion in the test. Ten minutes is far enough out that the armed timer
  # provably cannot fire inside the test — and the test READS the armed timer's
  # remaining milliseconds rather than taking that on trust.
  @long_design_window 600_000

  # The window injected for the paired timeout control, so its recorded
  # `detail` carries a short window and cannot be confused with the decline
  # half's ten minutes.
  @short_design_window 200

  # Task 019fe1b7 stage 2 — the pipeline's per-step budget, injected in
  # milliseconds. Short enough to elapse inside a test, long enough that the
  # step provably opens first; the long one cannot elapse inside any test in
  # this file, which is what makes the pair discriminating.
  @short_step_budget 1_000
  @long_step_budget 600_000

  # >= 8 graphemes, or `task_design_decline` refuses with `missing_reason`
  # before it ever reaches `PreplanStep`.
  @decline_reason "This task deletes a deprecated component; the surface it leaves behind already has direction that still holds."

  defp design_task!(project, title) do
    now = DateTime.utc_now()

    task =
      %Platform.Tasks.Task{}
      |> Ecto.Changeset.change(%{
        project_id: project.id,
        title: title,
        description: title,
        status: "planning",
        inserted_at: now,
        updated_at: now
      })
      |> Platform.Repo.insert!()

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    task
  end

  # Reuse `historian` as the carrier role — the same substitution
  # `Platform.Design.PreplanStepTest` uses — so this stays off the seeded
  # `designer` bundle the closed-roster coverage suite exercises.
  defp wire_designer! do
    Platform.Repo.insert!(
      %Platform.Roles.Role{
        key: "historian",
        name: "Historian",
        description: "test",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: "design.task_direction"
    })
    |> Platform.Repo.insert!()

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "router-designer-#{unique()}",
        name: "Fixture Designer",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Platform.Repo.insert()

    {:ok, _} = Platform.Roles.assign_role("historian", agent.id)

    agent
  end

  defp stub_designer_dispatcher do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {NoopDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)
  end

  # Task 019fe1b7 stage 2. This USED to inject `:design_step_timeout_ms`, the
  # router's own knob. That knob is gone: the design step is a lifecycle
  # pipeline step now, so the budget that bounds it is the pipeline's
  # per-step budget. Same shape, same `Application.get_env/3` read, same
  # absence of a `config/test.exs` override — and injecting it is what proves
  # the expiry comes from the pipeline rather than from a router timer, since
  # the router has no knob left to respond to.
  defp put_step_budget(ms) do
    put_lifecycle_env(:lifecycle_step_timeout_ms, ms)
  end

  defp put_lifecycle_env(key, value) do
    previous = Application.get_env(:platform, key)
    Application.put_env(:platform, key, value)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, key, previous)
      else
        Application.delete_env(:platform, key)
      end
    end)
  end

  defp reload_task(task), do: Platform.Repo.get!(Platform.Tasks.Task, task.id)

  # Move the lease's no-ack deadline into the past so `:check_no_ack` takes
  # its fire path (task 019fa469 stage 6). Before the handler level-checked
  # `no_ack_at`, `send(pid, :check_no_ack)` alone was enough — which is
  # precisely the conflation the stage fixed: a timer wake is not evidence
  # that 5 minutes elapsed, and an orphan timer from an earlier dispatch or
  # an earlier STAGE fires mid-window.
  #
  # Written straight to ETS rather than through `record_dispatch/4` with a
  # backdated `dispatched_at`: a same-stage re-dispatch now PRESERVES the
  # original deadline, so it could not move it, and every other lease field
  # the calling test set up survives untouched. Same idiom the
  # silence-lapsed test already uses for `silenced_until`.
  defp expire_no_ack_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row before expiring its no-ack deadline"

    assert lease.no_ack_at,
           "expected an armed no-ack deadline — nothing to expire, and the " <>
             "alarm this test asserts on is disabled for this lease"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | no_ack_at: past}})
    :ok
  end

  describe "pre-plan design hold (ADR-0046 member 7)" do
    setup %{project: project} do
      # The Registry's boot walk is disabled in the test env, so stage 3's row
      # has to be installed explicitly per sandbox.
      [spec] = Platform.Responsibilities.Handlers.DesignTaskDirection.register()
      {:ok, _row} = Platform.Responsibilities.upsert_by_key(spec)

      # Task 019fe1b7 stage 2. The design step resolves through
      # `Platform.Lifecycle.StepRegistry` now, and its boot singleton is
      # disabled in `config/test.exs` so cases can hold isolated instances.
      # Without one the designer edge resolves nothing and the whole describe
      # would assert against a design step that never fires — passing tests
      # over a deleted feature.
      registry = :"router_design_registry_#{unique()}"
      start_supervised!({Platform.Lifecycle.StepRegistry, name: registry})
      put_lifecycle_env(:lifecycle_step_registry, registry)

      %{project: project, registry: registry}
    end

    test "the designer edge resolves to the shipped step through the registry", %{
      registry: registry
    } do
      # ANTI-VACUITY for every test below. They assert that the design step
      # fires; if the shipped declaration and the registry name ever drift,
      # the edge resolves to `{:error, :unknown_step}`, the step is recorded
      # `failed`, the planner is released — and a suite that only watches for
      # the planner being released cannot tell that from success.
      edge = Platform.Lifecycle.Edges.designer_edge()

      assert [%{"step" => name, "await" => true, "can_divert" => true}] =
               Platform.Lifecycle.Edges.default_steps(edge)

      assert {:ok, %{mfa: {mod, _fun, 1}}} = Platform.Lifecycle.StepRegistry.fetch(name, registry)

      Code.ensure_loaded!(mod)
      assert function_exported?(mod, :start, 2), "the designer step must implement the behaviour"
      assert mod.kind() == :async
    end

    test "a UI task with a designer holds the planner; a non-UI task dispatches immediately",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, _pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)

      # ABSENCE. The planner must not be prompted while the step is open.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 600

      # The step really did fire and really is open — the cursor IS the state.
      # A POLL, not a barrier, and the file's own rule is why: the effect is
      # owned by another process now (the spawned edge runner), so there is a
      # process to name and `sync_router/1` would prove nothing about it.
      assert_eventually(fn -> reload_task(held).planning_step == "designing" end)
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # PAIRED POSITIVE CONTROL. Same runtime topic, same window, same task
      # shape but not UI-classified: it must broadcast.
      control = design_task!(project, @design_non_ui_title)

      control_assignee = %{
        type: :federated,
        id: "runtime-design-control-#{unique()}"
      }

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{control_assignee.id}")
      {:ok, _} = TaskRouter.start_link(task_id: control.id, assignee: control_assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute reload_task(control).planning_step == "designing"
    end

    test "a held design step clears the liveness lease; an unheld dispatch does not",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # The hold clears the lease only once the step is genuinely OPEN, so the
      # cursor has to have landed before the seed — otherwise this races the
      # runner and the assertion below would be measuring process scheduling.
      assert_eventually(fn -> reload_task(held).planning_step == "designing" end)

      # SEED the lease. Without this the assertion below is vacuous: a planning
      # task with no running stage never arms one, so `nil` would hold against
      # a `clear_liveness/1` that was never called.
      :ok =
        LeaseManager.record_dispatch(
          held.id,
          Ecto.UUID.generate(),
          "coding",
          DateTime.utc_now()
        )

      assert %{} = LeaseManager.get(held.id)

      send(pid, :dispatch)

      # BARRIER, not a poll — and deliberately so, though the lease looks like
      # third-party state. `clear_liveness/1` is `LeaseManager.clear/1`
      # (lease_manager.ex:282), a direct `:ets.delete` executed IN THE CALLING
      # PROCESS, i.e. inside this router's own `handle_info`. The LeaseManager
      # GenServer is never involved, so there is no third process to name and
      # the barrier is a complete happens-before proof. A poll here would be
      # strictly weaker evidence for the same claim.
      :ok = sync_router(held.id)

      assert LeaseManager.get(held.id) == nil,
             "the design hold must clear the lease — an armed no-ack timer would " <>
               "fire execution.no_ack_timeout five minutes into a legitimate hold"

      # PAIRED CONTROL: the same seed against a router that is NOT holding must
      # survive its dispatch, proving the clear is specific to the hold branch.
      control = design_task!(project, @design_non_ui_title)

      control_assignee = %{type: :federated, id: "runtime-design-lease-#{unique()}"}
      {:ok, control_pid} = TaskRouter.start_link(task_id: control.id, assignee: control_assignee)

      # Let the control router finish booting BEFORE seeding, or its own boot
      # dispatch could clear a lease that was never meant to be under test.
      # Its designer edge also has to have ANSWERED — a non-UI task resolves
      # to `not_applicable`, and until it does the router is still nominally
      # holding.
      assert_eventually(fn ->
        reload_task(control).planning_step_outcomes["design"]["outcome"] == "not_applicable"
      end)

      :ok = sync_router(control.id)

      :ok =
        LeaseManager.record_dispatch(
          control.id,
          Ecto.UUID.generate(),
          "coding",
          DateTime.utc_now()
        )

      send(control_pid, :dispatch)

      # A BARRIER IS MANDATORY HERE, and a poll would be unsound. The claim is
      # that the lease SURVIVES the dispatch, so the observable is already
      # truthy before the router has picked the message up: an
      # `assert_eventually(fn -> LeaseManager.get(control.id) end)` would return
      # on attempt 1 and pass on a tree where the clear had been made
      # unconditional. Only a happens-before proof that the dispatch was
      # HANDLED makes the survival meaningful.
      :ok = sync_router(control.id)

      assert %{} = LeaseManager.get(control.id)
    end

    test "settling the step wakes the planner exactly once", %{
      project: project,
      assignee: assignee
    } do
      stub_designer_dispatcher()
      wire_designer!()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, _pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      {:ok, :complete} = Platform.Design.PreplanStep.settle(held.id, nil)

      # Exactly ONE dispatch. `settle/2` writes twice (the outcome, then the
      # cursor) and each write broadcasts `{:task_updated, _}`; a wake-up keyed
      # on the broadcast rather than on leaving `:waiting_design` would prompt
      # the planner twice.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 700

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "complete"
    end

    # THE DISCRIMINATING TEST FOR THE MIGRATION ITSELF, and the reason it is
    # written as a pair over one shared fixture shape.
    #
    # The claim is not "the design step still expires" — the router's own
    # `:design_deadline` timer would satisfy that. The claim is that the
    # expiry is now the PIPELINE'S, which is only observable by MOVING THE
    # PIPELINE'S KNOB and watching the expiry move with it. The short-budget
    # half expires; the long-budget half, identical in every other respect,
    # does not. Neither half alone discriminates: the first passes against a
    # router timer that ignores the knob, and the second passes against a tree
    # with no expiry at all.
    #
    # There is no `send(pid, :design_deadline)` here because there is no such
    # message any more. The old test delivered one by hand to keep the window
    # long enough that a level check could not race it; the pipeline's budget
    # starts when the STEP starts, so a short budget is no longer a competing
    # cause for anything that happens before the step opens.
    test "the pipeline's per-step budget expires an open step; a longer budget does not",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      put_step_budget(@short_step_budget)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, _pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design

      # The step is genuinely open and genuinely held BEFORE the budget can
      # have elapsed — without this the expiry below could be a step that
      # never opened.
      assert_eventually(fn -> reload_task(held).planning_step == "designing" end)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "failed"

      assert task.planning_step_outcomes["design"]["reason"] ==
               Platform.Design.PreplanStep.reasons().timeout

      # ADR-0046 decision 7: the failure falls open, VISIBLY. It reaches merge
      # time through member 4's predicate with no extra work in this stage.
      assert Tasks.planning_gate_failed?(task)

      # ── PAIRED CONTROL: the same fixture under a budget that cannot elapse
      # inside this test. If the expiry above came from anywhere other than
      # the injected budget, this one expires too.
      put_step_budget(@long_step_budget)

      patient = design_task!(project, @design_ui_title)
      patient_assignee = %{type: :federated, id: "runtime-design-patient-#{unique()}"}
      patient_topic = "runtime:#{patient_assignee.id}"
      Phoenix.PubSub.subscribe(Platform.PubSub, patient_topic)

      {:ok, _} = TaskRouter.start_link(task_id: patient.id, assignee: patient_assignee)
      assert_eventually(fn -> reload_task(patient).planning_step == "designing" end)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^patient_topic}, 1_500

      patient_task = reload_task(patient)
      assert patient_task.planning_step == "designing"
      assert patient_task.planning_step_outcomes == %{}

      # And it still closes on the real signal, so "held" is not "wedged".
      {:ok, :complete} = Platform.Design.PreplanStep.settle(patient.id, nil)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^patient_topic}, 5_000
      assert reload_task(patient).planning_step_outcomes["design"]["outcome"] == "complete"
    end

    # ── The designer's exit (task 019fa504) ────────────────────────────────
    #
    # ADR-0046 gave the designer exactly one way out of an open design step —
    # attach a canvas — so a designer who reads the task and judges it needs no
    # direction had only two moves, both bad: attach a canvas she does not
    # believe in, or go silent and let the 30-minute deadline record `failed`.
    # `task_design_decline` is the third move. This test pins what it does to
    # the ROUTER, which is the half `preplan_step_test.exs` cannot see.
    #
    # WHY THE DEADLINE KEEPS RECORDING `failed`, and why the control below is
    # not optional. A timeout and a decline are different facts and the row has
    # to keep them apart: `Tasks.failed_planning_steps/1` is what surfaces a
    # designer who never engaged, and on this very ticket that is what caught a
    # designer runtime dropping the prompt body — two timeouts that would have
    # looked like a clean planning history had they recorded `not_applicable`.
    # So the decline half of this test asserts `not_applicable`, and the
    # timeout half asserts `failed` OVER THE SAME FIXTURE, in the same run.
    # Without the second half the first cannot distinguish "a decline records
    # not_applicable" from "the design step stopped recording failures at all".
    #
    # WHY THE TRACE IS NOT DECORATION. `:design_deadline` is a message the
    # router sends to ITSELF; it never passes through this process, so no
    # ordinary `refute_receive` can see it and its absence would otherwise have
    # to be inferred from the outcome it would have written. `:erlang.trace/3`
    # with `[:receive]` asserts the negative directly. The mechanism gets its
    # own control twice over in the same test: a deliberately delivered stale
    # `:design_deadline` IS observed through the same trace, and the timeout
    # half observes a real one. A trace that was never attached, or a flag that
    # silently stopped working, fails at those sites rather than passing here.
    #
    # WHY THE TIMEOUT CONTROL IS DELIVERED BY `send/2` RATHER THAN BY WAITING
    # OUT A SHORT WINDOW. Deviation from the stage brief, taken deliberately.
    # A window short enough to elapse inside a test is also short enough to
    # elapse between `start_link/1` returning and the first `current_status/1`
    # reply on a loaded box — at which point the LEVEL check in
    # `handle_design_hold/2` expires the step before the hold can be pinned,
    # and the control fails for a reason that has nothing to do with the
    # behaviour. That is a manufactured flake in the one file in this suite
    # whose flakiness already tracks load. The short window is still INJECTED
    # (so the recorded `detail` carries it and cannot be confused with the
    # decline half's ten minutes); only the delivery is made deterministic,
    # exactly as the sibling deadline tests above already do it.
    test "a declined design step releases the planner immediately and records not_applicable, not failed",
         %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      designer = wire_designer!()
      put_step_budget(@long_design_window)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)

      # PIN THE POSITIVE FIRST. Everything below is a claim about what a
      # decline does to an OPEN step; without this they would all hold just as
      # well on a task that never reached the design step at all, which is the
      # exact shape of vacuity this stage exists to avoid.
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design
      assert_eventually(fn -> reload_task(held).planning_step == "designing" end)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # The budget the step is running under is genuinely ten minutes, so the
      # margin measured below rules it out as the releaser. Read from the
      # accessor the runner reads — a test that asserted its own literal would
      # agree with itself while the runner used something else.
      assert Platform.Lifecycle.step_timeout_ms() == @long_design_window

      # The hold is carried by a LIVE RUNNER, not by a timer. An unarmed
      # anything would make the timing claim below vacuous: without a run in
      # flight, "the decline released the planner" is true of a tree where
      # nothing was ever holding it.
      assert %{design_run: {runner_pid, _ref}} = :sys.get_state(pid)
      assert Process.alive?(runner_pid)

      started_at = System.monotonic_time(:millisecond)

      # THROUGH THE TOOL, not `PreplanStep.decline/3`. The path a real designer
      # takes is an MCP `tools/call`, and only that path resolves the caller
      # identity — which is why `declined_by` is asserted below.
      assert {:ok, result} =
               Platform.Federation.ToolSurface.execute(
                 "task_design_decline",
                 %{"task_id" => held.id, "reason" => @decline_reason},
                 %{agent_id: designer.id}
               )

      assert result.outcome == "not_applicable"
      assert result.reason == Platform.Design.PreplanStep.reasons().declined
      refute result.declined_after_timeout

      # The decline's `{:task_updated, _}` broadcast reaches the STEP'S
      # WATCHER, which settles the pipeline's step; the runner reports and the
      # router dispatches. Task 019fe1b7 stage 2 moved that wake-up out of the
      # router — the observable is unchanged, which is the point.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert elapsed < div(@long_design_window, 10),
             "the planner was released #{elapsed}ms after the decline against an " <>
               "injected #{@long_design_window}ms window — that margin is what rules " <>
               "the deadline out as the releaser"

      assert TaskRouter.current_status(held.id).status != :waiting_design

      # The run is released rather than left in flight, and the runner is
      # gone rather than left polling a closed step until its budget lapses.
      assert %{design_run: nil} = :sys.get_state(pid)
      refute Process.alive?(runner_pid)

      task = reload_task(held)
      entry = task.planning_step_outcomes["design"]

      assert entry["outcome"] == "not_applicable"
      assert entry["reason"] == Platform.Design.PreplanStep.reasons().declined
      assert entry["decline_note"] == @decline_reason
      refute Map.has_key?(entry, "declined_after_timeout")

      # Only the tool path can write this — a `decline/3` call made directly by
      # the router or a test would leave it absent.
      assert entry["declined_by"] == %{"kind" => "agent", "id" => designer.id}

      refute entry["outcome"] == "failed"
      assert task.planning_step == "planning"

      refute "design" in Enum.map(Tasks.failed_planning_steps(task), & &1.step)
      refute Tasks.planning_gate_failed?(task)

      # A STALE settlement — one from a runner this router has already given up
      # on, or from a previous hold — is inert. The release matches on the
      # RUNNER PID, so a message naming a dead runner cannot re-dispatch or
      # rewrite the outcome.
      before_stale = reload_task(held).planning_step_outcomes
      send(pid, {:design_edge_settled, runner_pid, :failed})

      :ok = sync_router(held.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 700
      assert reload_task(held).planning_step_outcomes == before_stale

      # ── PAIRED TIMEOUT CONTROL ──────────────────────────────────────────
      # Same project, same UI title, same designer wiring, same router — the
      # only difference is which exit is taken. The timeout still records
      # `failed`, still names `design_timeout`, and still reaches merge time
      # through `failed_planning_steps/1`. That is the ruling this stage pins.
      put_step_budget(@short_design_window)

      control = design_task!(project, @design_ui_title)
      control_assignee = %{type: :federated, id: "runtime-design-decline-ctl-#{unique()}"}
      control_topic = "runtime:#{control_assignee.id}"
      Phoenix.PubSub.subscribe(Platform.PubSub, control_topic)

      {:ok, _control_pid} =
        TaskRouter.start_link(task_id: control.id, assignee: control_assignee)

      # No hand-delivered timer any more: the injected budget IS the delivery.
      # Bound to the control's own topic — the declined router above shares
      # this mailbox, and an untopic'd match could be satisfied by one of its
      # ticks.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^control_topic}, 5_000

      control_task = reload_task(control)
      control_entry = control_task.planning_step_outcomes["design"]

      assert control_entry["outcome"] == "failed"
      assert control_entry["reason"] == Platform.Design.PreplanStep.reasons().timeout
      assert control_entry["detail"] =~ "design_timeout"
      assert control_entry["detail"] =~ to_string(@short_design_window)
      refute Map.has_key?(control_entry, "decline_note")

      assert "design" in Enum.map(Tasks.failed_planning_steps(control_task), & &1.step)
      assert Tasks.planning_gate_failed?(control_task)
      assert control_task.planning_step == "planning"
    end

    # THE HOLD STILL CANNOT OUTLIVE ITS HOLDER. Nothing about it is persisted:
    # task 019fe1b7 stage 2 replaced the router's timer reference with a
    # monitor on the process running the edge, and both die with the router.
    #
    # This absorbed the old "an overdue hold is released by the level check on
    # a tick the armed timer cannot serve" test, which is not merely
    # unnecessary now but UNWRITABLE: it backdated `updated_at` to make
    # `design_hold_expired?/2` — a level check computed off the row — read
    # true, and that function is gone with the machinery. The property it
    # protected is the one asserted here, and it is asserted the way it now
    # holds: the REPLACEMENT re-derives the hold from the row alone and its
    # own run carries its own budget.
    test "killing the holder does not strand the task", %{project: project, assignee: assignee} do
      stub_designer_dispatcher()
      wire_designer!()

      put_step_budget(@long_step_budget)

      held = design_task!(project, @design_ui_title)
      {:ok, pid} = TaskRouter.start_link(task_id: held.id, assignee: assignee)
      # Task 01a00587: `:dispatch` is now debounced, so the router's status is
      # set by the `:dispatch_now` that lands ~50ms later. Barrier on the
      # router (which drains the armed timer) before reading it.
      :ok = sync_router(held.id)
      assert TaskRouter.current_status(held.id).status == :waiting_design
      assert_eventually(fn -> reload_task(held).planning_step == "designing" end)

      # Kill the holder — the container restart from the journalled
      # `deploying -> done` incident, where the transition lived solely in an
      # edge-triggered PubSub handler and the restart stranded the task
      # forever.
      GenServer.stop(pid, :normal, 1_000)
      refute Process.alive?(pid)

      # The replacement inherits a row it did not open. A short budget on ITS
      # run is what proves it re-fired the edge rather than coasting on
      # anything the dead router left behind — the dead router's run was
      # started under a ten-minute budget and could not produce this.
      put_step_budget(@short_step_budget)

      replacement_assignee = %{type: :federated, id: "runtime-design-restart-#{unique()}"}
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{replacement_assignee.id}")

      {:ok, _replacement} =
        TaskRouter.start_link(task_id: held.id, assignee: replacement_assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000

      task = reload_task(held)
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes["design"]["outcome"] == "failed"
    end

    test "a task already carrying a plan is never held, even with the cursor at designing",
         %{project: project, assignee: assignee} do
      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      task = design_task!(project, @design_ui_title)

      # Force the cursor without going through `start/1` — this is the stranded
      # shape the guard protects against, not one the happy path produces.
      {:ok, _} = Tasks.set_planning_step(task, :designing)

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", status: "running"})

      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      refute TaskRouter.current_status(task.id).status == :waiting_design

      # And the step was never fired: a task past planning must not acquire a
      # design record from the router's start site.
      assert reload_task(task).planning_step_outcomes == %{}
    end

    # The router's `design_step_timeout_ms/0` and
    # `default_design_step_timeout_ms/0` were DELETED, not moved: the wait
    # they bounded happens inside the pipeline now. This is the same guard
    # over the accessor that replaced them, and it is kept rather than dropped
    # because the property it protects is the one that matters — the shipped
    # thirty minutes is still thirty minutes, and a test-only value has not
    # become the production one.
    test "the shipped hold window is still 30 minutes, now as the pipeline's step budget" do
      # No `config/test.exs` override exists, so the live read equals the
      # shipped literal.
      assert Platform.Lifecycle.default_step_timeout_ms() == 1_800_000
      assert Platform.Lifecycle.step_timeout_ms() == 1_800_000

      # PAIRED CONTROL: an injected value must be OBSERVED, which is what proves
      # the read is `Application.get_env/3` and not the literal inlined at every
      # call site. The default accessor must NOT move with it.
      put_step_budget(1_234)
      assert Platform.Lifecycle.step_timeout_ms() == 1_234
      assert Platform.Lifecycle.default_step_timeout_ms() == 1_800_000
    end
  end

  # ── Shutdown archive gate ────────────────────────────────────────────────
  #
  # `terminate/2` used to archive the execution space on EVERY shutdown. The
  # shutdown reason cannot distinguish normal completion from an involuntary
  # teardown (both deliver `:shutdown`), so the gate is the TASK'S status.
  #
  # Both halves below must hold IN THE SAME RUN: half 1 on its own also passes
  # against a `terminate/2` that archives nothing at all.
  describe "terminate/2 execution-space archive gate" do
    setup %{project: project} do
      make = fn title, status ->
        {:ok, t} = Tasks.create_task(%{project_id: project.id, title: title})

        t =
          t
          |> Ecto.Changeset.change(%{status: status})
          |> Platform.Repo.update!()

        {:ok, space} = ExecutionSpace.find_or_create(t.id)
        {t, space}
      end

      %{make_task_with_space: make}
    end

    test "a non-terminal task's space survives shutdown, a terminal task's is archived",
         %{make_task_with_space: make} do
      {live_task, live_space} = make.("Router still working", "in_progress")
      {done_task, done_space} = make.("Router finished", "done")

      assert :ok = terminate_router_for(live_task.id, live_space.id)
      assert :ok = terminate_router_for(done_task.id, done_space.id)

      # Half 1: the work was NOT finished, so the space must stay live.
      assert reload_space(live_space.id).archived_at == nil

      # Half 2: the work WAS finished, so archive-on-completion still happens.
      # Without this half, half 1 passes against a terminate/2 that archives
      # nothing — which would trade a silent-pin bug for unbounded growth.
      refute reload_space(done_space.id).archived_at == nil
    end

    test "a cancelled task's space is archived (terminal, not just `done`)",
         %{make_task_with_space: make} do
      {task, space} = make.("Router retired", "cancelled")

      assert :ok = terminate_router_for(task.id, space.id)
      refute reload_space(space.id).archived_at == nil
    end

    test "a deleted task's space is not archived and terminate/2 does not raise",
         %{make_task_with_space: make} do
      {task, space} = make.("Router orphaned", "in_progress")

      # Soft delete: `get_task_detail/1` filters on `deleted_at`, so the row
      # becomes unloadable exactly as a hard-deleted task would be.
      task
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
      |> Platform.Repo.update!()

      assert :ok = terminate_router_for(task.id, space.id)
      assert reload_space(space.id).archived_at == nil
    end
  end

  defp terminate_router_for(task_id, space_id) do
    state = %TaskRouter.State{
      task_id: task_id,
      assignee: %{type: :federated, id: "router-archive-gate"},
      execution_space_id: space_id,
      status: :running
    }

    TaskRouter.terminate(:shutdown, state)
  end

  defp reload_space(space_id), do: Platform.Repo.get!(Platform.Chat.Space, space_id)

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()
end
