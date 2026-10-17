defmodule Platform.Orchestration.LateAckReconcileTest do
  @moduledoc """
  Task 01a0e7ac stage 2: a `task_ack` that lands AFTER the 300 s no-ack alarm
  blocked the task clears that block, and nothing else does.

  ## Every state is DRIVEN, not constructed

  * the no-ack block is the real alarm: `expire_no_ack_deadline!/1` moves the
    lease's `no_ack_at` into the past and `send(router, :check_no_ack)` runs
    `fire_no_ack_alert/2`, which writes `blocked_cause` (stage 1);
  * the router is then STOPPED, which runs `TaskRouter.terminate/2` ->
    `clear_liveness/1`. In production `TaskRouterWatcher.evaluate_task/1` does
    exactly that the moment the task goes `blocked` (the watcher is disabled in
    test). This matters for the non-owner control: with a live ETS lease,
    `task_ack` refuses a non-owner before any row is written, and the control
    would pass without the reconcile's own owner check ever running;
  * the ack is `ToolSurface.execute("task_ack", ...)`, the real MCP entry
    point, except in the stale-ack control, where the tool refuses a
    non-running stage id and the row is written with `record_runtime_event/1`;
  * the needs_human hold is `ToolSurface.execute("report_blocker", ...)`.

  Only the clock is poked, as in `task_router_acked_stage_no_ack_test.exs`.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.{ExecutionSpace, LateAckReconcile, LeaseManager, TaskRouter}
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransitions

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})
    %{runtime_id: "runtime-late-ack-#{System.unique_integer([:positive])}"}
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp build!(ctx, status \\ "in_progress") do
    {:ok, project} =
      Tasks.create_project(%{name: "Late Ack #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Late ack reconcile",
        description: "Pin the late-ack reconcile",
        status: status,
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    {:ok, next_stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "Wire it up",
        description: "coding — stage 2"
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: next_stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: ctx.runtime_id}

    on_exit(fn ->
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{task: task, stage: stage, next_stage: next_stage, assignee: assignee}
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp boot_router!(f) do
    {:ok, pid} = TaskRouter.start_link(task_id: f.task.id, assignee: f.assignee)
    :ok = sync_router(f.task.id)
    pid
  end

  # The watcher's reaction to `blocked`: stop the router, which clears the
  # ETS lease in `terminate/2`.
  defp stop_router_as_watcher_would!(task_id) do
    stop_router(task_id)
    assert LeaseManager.get(task_id) == nil, "terminate/2 must clear the ETS lease"
  end

  defp no_ack_block!(f) do
    pid = boot_router!(f)
    lease = LeaseManager.get(f.task.id)
    assert lease.no_ack_at, "expected an armed no-ack deadline"
    assert lease.owner_runtime_id == f.assignee.id
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {f.task.id, %{lease | no_ack_at: past}})

    send(pid, :check_no_ack)
    :ok = sync_router(f.task.id)

    record = Tasks.get_task_record(f.task.id)
    assert record.status == "blocked"
    assert record.metadata["blocked_cause"]["kind"] == "execution.no_ack_timeout"

    stop_router_as_watcher_would!(f.task.id)
    record
  end

  defp safety_net_block!(f) do
    pid = boot_router!(f)
    lease = LeaseManager.get(f.task.id)
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {f.task.id, %{lease | safety_net_at: past}})

    send(pid, :check_safety_net)
    :ok = sync_router(f.task.id)

    record = Tasks.get_task_record(f.task.id)
    assert record.status == "blocked"
    assert record.metadata["blocked_cause"]["kind"] == "execution.safety_net_fired"

    stop_router_as_watcher_would!(f.task.id)
    record
  end

  defp ack!(f, stage, runtime_id) do
    assert {:ok, _} =
             ToolSurface.execute(
               "task_ack",
               %{
                 "task_id" => f.task.id,
                 "stage_id" => stage.id,
                 "subagent_id" => "subagent-late-#{System.unique_integer([:positive])}"
               },
               %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(runtime_id)}
             )

    :ok
  end

  defp needs_human_blocker!(f, stage, runtime_id) do
    assert {:ok, %{blocked: true}} =
             ToolSurface.execute(
               "report_blocker",
               %{
                 "task_id" => f.task.id,
                 "stage_id" => stage.id,
                 "description" => "needs a person",
                 "category" => "decision",
                 "needs_human" => true,
                 "memory_ref" => "org/page/identity.md",
                 "attempts" => ["tried one", "tried two", "tried three"],
                 "unblock_action" => "A person picks option A or B"
               },
               %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(runtime_id)}
             )

    :ok
  end

  defp status(f), do: Tasks.get_task_record(f.task.id).status

  defp reconciled_transitions(f) do
    f.task.id
    |> PhaseTransitions.list_for_task()
    |> Enum.filter(&(&1.via == "late_ack_reconciled"))
  end

  defp late_ack_notices(f) do
    space = ExecutionSpace.find_by_task_id(f.task.id)
    assert space, "expected an execution space"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.map(& &1.content)
    |> Enum.filter(&String.starts_with?(&1, "Late ack reconciled:"))
  end

  # ── happy path ─────────────────────────────────────────────────────────

  describe "the owner acks the timed-out stage late" do
    test "restores the prior status, attributed to system via late_ack_reconciled", ctx do
      f = build!(ctx)
      no_ack_block!(f)

      :ok = ack!(f, f.stage, f.assignee.id)

      record = Tasks.get_task_record(f.task.id)
      assert record.status == "in_progress"
      refute Map.has_key?(record.metadata, "blocked_cause")
      assert String.starts_with?(record.metadata["blocked_reason"], "Executor never acked")

      assert [transition] = reconciled_transitions(f)
      assert transition.from_status == "blocked"
      assert transition.to_status == "in_progress"
      assert transition.actor_kind == "system"
      assert transition.actor_label == "system:auto"

      assert [notice] = late_ack_notices(f)
      refute String.starts_with?(notice, "Blocker reported:")
      assert String.contains?(notice, f.stage.id)
      assert String.contains?(notice, f.assignee.id)
    end

    test "deploy shape: a task blocked from deploying returns to deploying", ctx do
      f = build!(ctx, "deploying")
      record = no_ack_block!(f)
      assert record.metadata["blocked_cause"]["prior_status"] == "deploying"

      :ok = ack!(f, f.stage, f.assignee.id)

      assert status(f) == "deploying"
      assert [%{to_status: "deploying"}] = reconciled_transitions(f)
    end

    test "maybe_reconcile/3 is a no-op once the block is cleared", ctx do
      f = build!(ctx)
      no_ack_block!(f)
      :ok = ack!(f, f.stage, f.assignee.id)
      assert status(f) == "in_progress"

      assert {:skip, :not_blocked} =
               LateAckReconcile.maybe_reconcile(f.task.id, f.stage.id, f.assignee.id)

      assert length(reconciled_transitions(f)) == 1
    end
  end

  # ── negative controls ─────────────────────────────────────────────────

  describe "control 1: a needs_human hold keeps the task blocked" do
    test "owner files report_blocker(needs_human: true) on the timed-out stage, then acks",
         ctx do
      f = build!(ctx)
      no_ack_block!(f)
      :ok = needs_human_blocker!(f, f.stage, f.assignee.id)

      :ok = ack!(f, f.stage, f.assignee.id)

      assert status(f) == "blocked"
      assert reconciled_transitions(f) == []

      assert Tasks.get_task_record(f.task.id).metadata["blocked_cause"]["kind"] ==
               "execution.no_ack_timeout"
    end

    test "a task blocked with no cause plus a needs_human lease stays blocked on ack", ctx do
      f = build!(ctx)
      {:ok, _} = Tasks.transition_task_status(f.task, "blocked")
      :ok = needs_human_blocker!(f, f.stage, f.assignee.id)

      :ok = ack!(f, f.stage, f.assignee.id)

      assert status(f) == "blocked"
      assert reconciled_transitions(f) == []
    end
  end

  describe "control 2: a stale ack for a different stage" do
    test "is persisted but clears nothing", ctx do
      f = build!(ctx)
      no_ack_block!(f)

      {:ok, _event} =
        Orchestration.record_runtime_event(%{
          "task_id" => f.task.id,
          "phase" => "execution",
          "runtime_id" => f.assignee.id,
          "event_type" => "execution.acked",
          "payload" => %{
            "stage_id" => f.next_stage.id,
            "runtime_id" => f.assignee.id,
            "subagent_id" => "subagent-stale"
          }
        })

      assert Orchestration.last_stage_ack_at(f.task.id, f.next_stage.id, f.assignee.id)
      assert status(f) == "blocked"
      assert reconciled_transitions(f) == []
    end
  end

  describe "control 3: an ack from a runtime that was not the lease owner" do
    test "stays blocked", ctx do
      f = build!(ctx)
      no_ack_block!(f)

      :ok = ack!(f, f.stage, "runtime-intruder-#{System.unique_integer([:positive])}")

      assert status(f) == "blocked"
      assert reconciled_transitions(f) == []
    end
  end

  describe "control 4: a block with a different cause" do
    test "a safety-net block is not cleared by an owner ack", ctx do
      f = build!(ctx)
      safety_net_block!(f)

      :ok = ack!(f, f.stage, f.assignee.id)

      assert status(f) == "blocked"
      assert reconciled_transitions(f) == []
    end
  end

  describe "compare-and-set" do
    test "a person re-blocking between the read and the write wins", ctx do
      f = build!(ctx)
      as_read = no_ack_block!(f)

      # A person moves the task out of blocked and blocks it again by hand.
      # The new episode has no cause; the struct the reconcile read still
      # shows the old one.
      {:ok, moved} = Tasks.transition_task_status(Tasks.get_task_record(f.task.id), "backlog")
      {:ok, _reblocked} = Tasks.transition_task_status(moved, "blocked")

      assert {:skip, :stale_base} =
               LateAckReconcile.reconcile(as_read, f.stage.id, f.assignee.id)

      record = Tasks.get_task_record(f.task.id)
      assert record.status == "blocked"
      refute Map.has_key?(record.metadata, "blocked_cause")
      assert reconciled_transitions(f) == []
    end
  end
end
