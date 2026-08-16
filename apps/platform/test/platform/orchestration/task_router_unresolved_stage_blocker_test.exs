defmodule Platform.Orchestration.TaskRouterUnresolvedStageBlockerTest do
  @moduledoc """
  The unresolved-stage state must be LOUD, whatever route reached it.

  Task `01a006e7` stage 2. The invariant: a task at `in_progress` with an
  `approved` plan always has at least one stage `pending` or `running`.
  Violating it for more than one dispatch interval is a real blocker. Before
  this stage the state emitted an INFO line and a `:dispatch_suppressed`
  telemetry event and nothing red.

  This is a SAFETY NET, not the fix. Stage 3 fixes the review-bounce route;
  the deploy-failure bounce and a human-REJECTED `manual_approval` (task
  `019ff6c9`) reach the same shape by other routes and are NOT auto-repaired
  here — an agent must not clear a human's ruling. What those instances
  lacked was notice.

  ## ANTI-VACUITY (binding)

  The first test walks ONE harness through three dispatch ticks and asserts
  0 → 1 → 1 blockers. The "no blocker after one suppression" assertion is
  therefore a REAL negative: the very same fixture, router and query produce
  a row on the next tick, so a silent harness cannot be mistaken for a
  working threshold. The row is asserted on its content — `needs_human`,
  `phase`, and the reason text naming the task and the stage-status census —
  not merely on its existence.

  No `Process.sleep`. Two barriers: a telemetry handler that forwards every
  `:dispatch_suppressed` to the test (so the `init/1`-scheduled dispatch is
  awaited rather than raced), and `TaskRouter.current_status/1`, a
  `GenServer.call` answered only after every queued message is handled.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    test_pid = self()
    handler_id = "unresolved-stage-blocker-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :orchestration, :dispatch_suppressed],
      fn _event, _measure, meta, _cfg -> send(test_pid, {:dispatch_suppressed, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Unresolved Stage Guard Project",
        repo_url: "https://github.com/test/unresolved-stage-guard"
      })

    %{project: project}
  end

  describe "an in_progress task with no open stage" do
    test "raises exactly one needs_human blocker, on the SECOND consecutive suppression", %{
      project: project
    } do
      %{task: task} = exhausted_task(project)

      pid = start_router!(task)

      # Tick 1 — the dispatch `init/1` scheduled. Awaited via telemetry so the
      # count below is not racing it.
      assert_receive {:dispatch_suppressed, %{task_id: _, reason: :unresolved_stage}}, 2_000
      barrier(task)

      assert blockers(task) == [],
             "one withheld dispatch is not yet a blocker — the guard fires on the SECOND"

      # Tick 2 — the guard must fire here. That this call produces a row is
      # what makes the emptiness asserted above a real negative rather than a
      # dead harness.
      tick!(pid, task)

      assert [blocker] = blockers(task)
      assert blocker.phase == "execution"
      assert blocker.event_type == "execution.blocked"
      assert blocker.runtime_id == "task_router"
      assert blocker.payload["needs_human"] == true
      assert blocker.payload["reported_by"] == "task_router"

      description = blocker.payload["description"]
      assert description =~ task.id
      refute description =~ "no plan"
      assert description =~ "NO stage"
      assert description =~ "4 passed"
      assert description =~ "reopen_manual_approval"

      # Tick 3 — fires ONCE, not on a loop. A blocker per dispatch tick would
      # be a new bug, not a fix.
      tick!(pid, task)

      assert length(blockers(task)) == 1,
             "the escalation must latch: one blocker per unresolved-stage episode"
    end

    test "the counter resets when a stage reopens, and re-arms afterwards", %{project: project} do
      %{task: task, plan: plan} = exhausted_task(project)

      pid = start_router!(task)
      assert_receive {:dispatch_suppressed, %{reason: :unresolved_stage}}, 2_000
      barrier(task)
      assert blockers(task) == []

      # A stage reopens: the next dispatch RESOLVES, so the consecutive run
      # ends and the counter clears.
      last = plan |> stages() |> List.last()
      reopened = set_stage_status!(last, "pending")
      tick!(pid, task)

      refute_received {:dispatch_suppressed, %{reason: :unresolved_stage}}
      assert blockers(task) == []

      # Back to the bad shape. This is suppression #1 of a NEW run — no
      # blocker yet, precisely because the counter reset. Re-read the row
      # first: the resolved dispatch above may have moved the stage to
      # `running`, and a changeset built off a stale struct would no-op.
      reopened |> Platform.Repo.reload!() |> set_stage_status!("passed")
      tick!(pid, task)
      assert blockers(task) == [], "the counter must have reset when the dispatch resolved"

      # ...and the harness is alive: the next tick raises.
      tick!(pid, task)
      assert length(blockers(task)) == 1
    end
  end

  describe "a plan that legitimately has an open stage" do
    test "never trips the guard however many times it is dispatched", %{project: project} do
      %{task: task} = healthy_task(project)

      pid = start_router!(task)
      barrier(task)

      for _ <- 1..3 do
        send(pid, :dispatch_now)
        barrier(task)
      end

      refute_received {:dispatch_suppressed, %{reason: :unresolved_stage}}

      assert blockers(task) == [],
             "a task with a pending stage has a nameable dispatch subject — no escalation"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # `in_progress`, approved plan, EVERY stage settled: the shape a review
  # bounce (and a rejected manual_approval, and a failed deploy) leaves behind.
  defp exhausted_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Task with nowhere to work",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    for {name, position} <- [{"Schema", 1}, {"Context", 2}, {"LiveView", 3}, {"Review", 4}] do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
      {:ok, running} = Tasks.transition_stage(stage, "running")
      {:ok, _passed} = Tasks.transition_stage(running, "passed")
    end

    %{task: task, plan: plan}
  end

  defp healthy_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Task with somewhere to work",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, first} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Schema"})
    {:ok, running} = Tasks.transition_stage(first, "running")
    {:ok, _passed} = Tasks.transition_stage(running, "passed")
    {:ok, _pending} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Context"})

    %{task: task, plan: plan}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp tick!(pid, task) do
    send(pid, :dispatch_now)
    barrier(task)
  end

  defp barrier(task), do: TaskRouter.current_status(task.id)

  defp blockers(task) do
    Platform.Repo.all(
      from(e in RuntimeEvent,
        where: e.task_id == ^task.id and e.event_type == "execution.blocked",
        order_by: [asc: e.occurred_at]
      )
    )
  end

  defp stages(plan), do: Tasks.get_plan(plan.id).stages

  defp set_stage_status!(stage, status) do
    stage
    |> Ecto.Changeset.change(status: status)
    |> Platform.Repo.update!()
  end

  defp start_router!(task) do
    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
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

    pid
  end
end
