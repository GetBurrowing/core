defmodule Platform.Orchestration.TaskRouterSafetyNetSuppressionTest do
  @moduledoc """
  `handle_info(:check_safety_net, ...)` must not raise a human-facing blocker
  about a plan that has nothing left to be slow about (task 019fbe9e stage 4).

  ## The shape this file pins

  The safety-net lease is armed at dispatch and measures elapsed wall time. It
  never re-reads whether the stage it is measuring is still open. A plan that
  settles AFTER the lease is armed — every stage terminal, every validation
  terminal — therefore still trips the alarm at the end of the window, posting
  `needs_human=true` against a task with no work in flight.

  The precondition arrives LATE on purpose: the lease is armed while the stage
  is genuinely running, and only then is the plan settled. A fixture that
  settles the plan before arming the lease would pass against the unsuppressed
  handler too.

  ## Anti-vacuity

  Every refutation here is paired with a fixture that differs in exactly one
  field and MUST still fire. There are two, not one, because the predicate is a
  conjunction: one control leaves the stage `running`, the other leaves the
  stage `passed` with a single validation still `pending`. A suppression keyed
  on only one conjunct would survive a single control.

  Each refutation also asserts the lease is present and unfired immediately
  before the check, so "no alert" cannot be the handler's `nil`-lease early
  return standing in for the suppression under test.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Safety Net Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Safety-net suppression",
        description: "Pin the settled-plan suppression contract",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage one",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})
    {:ok, test} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{
      type: :federated,
      id: "runtime-safety-net-#{System.unique_integer([:positive])}"
    }

    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

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

      LeaseManager.clear(task.id)
    end)

    %{task: task, plan: plan, stage: stage, validations: [lint, test], assignee: assignee}
  end

  describe "the window elapses on a settled plan" do
    test "no safety-net event and no blocker when nothing is open", ctx do
      pid = boot_router!(ctx.task, ctx.assignee)

      # LATE: the lease was armed against a genuinely running stage above.
      settle_validations!(ctx.validations)
      settle_stage!(ctx.stage)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert blocker_count(ctx.task.id) == before_blockers

      # The one-shot is still consumed, so a later timer wake cannot
      # re-evaluate and turn a suppressed alert into a fired one.
      assert %{safety_net_fired?: true} = LeaseManager.get(ctx.task.id)
    end

    test "CONTROL: a still-running stage with pending validations fires", ctx do
      pid = boot_router!(ctx.task, ctx.assignee)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event,
                       %{event_type: "execution.safety_net_fired", stage_id: fired_stage_id}}

      assert fired_stage_id == ctx.stage.id
      assert blocker_count(ctx.task.id) == before_blockers + 1
    end

    test "CONTROL: a passed stage with ONE validation still pending fires", ctx do
      pid = boot_router!(ctx.task, ctx.assignee)

      # Differs from the suppressed fixture in exactly one field: the second
      # validation is left `pending`. This is the conjunct a stage-only
      # predicate would miss.
      [lint, _test] = ctx.validations
      settle_validations!([lint])
      settle_stage!(ctx.stage)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert blocker_count(ctx.task.id) == before_blockers + 1
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp boot_router!(task, assignee) do
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end

  # Written straight through the changeset rather than via
  # `PlanEngine.evaluate_validation/2`: the engine path can complete the plan,
  # and a completed plan CLEARS the lease — which would make the refutation
  # pass through the handler's `nil` early return instead of the suppression.
  defp settle_validations!(validations) do
    Enum.each(validations, fn v ->
      {:ok, _} =
        v
        |> Ecto.Changeset.change(%{status: "passed", evaluated_at: DateTime.utc_now()})
        |> Repo.update()
    end)
  end

  defp settle_stage!(stage) do
    {:ok, passed} = Tasks.transition_stage(stage, "passed")
    passed
  end

  # Drop the safety-net deadline into the past. The ONE field that separates
  # "the window has not elapsed" from "the window has elapsed".
  defp expire_safety_net_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row — the refutation would be vacuous without one"
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    refute lease.safety_net_fired?, "expected the one-shot to be unconsumed"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | safety_net_at: past}})
    :ok
  end

  defp blocker_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.count(&String.contains?(&1.content, "Stage safety-net exceeded"))
  end
end
