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

  describe "the window elapses on a gate only a human can pass" do
    test "a pending pr_merged under auto_merge:false parks instead of blocking", ctx do
      park_on_gate!(ctx, "pr_merged", false)
      pid = boot_router!(ctx.task, ctx.assignee)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      # One assertion per fact.
      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert_received {:runtime_event, %{event_type: "execution.awaiting_human_action"} = evt}
      assert evt.payload.pending_kinds == ["pr_merged"]
      assert evt.payload.gate == "pr_merge_auto_merge_false"

      assert blocker_count(ctx.task.id) == before_blockers
      assert notice_count(ctx.task.id) == 1
      refute needs_human_posted?(ctx.task.id)

      reloaded = Tasks.get_task_record(ctx.task.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["awaiting_human_action"] == "merge"
      assert is_binary(reloaded.metadata["awaiting_human_action_at"])

      # Shared JSONB: the column also carries these two, and they must
      # survive the stamp untouched.
      assert reloaded.metadata["blocked_reason"] == "a pre-existing reason"
      assert reloaded.metadata["unmet_dependencies"] == ["pre-existing-dep"]

      assert %{safety_net_fired?: true} = LeaseManager.get(ctx.task.id)
    end

    test "CONTROL: an agent-passable ci_passed on the SAME strategy still fires", ctx do
      # Differs from the parked fixture in exactly one field: the pending
      # validation's kind. Strategy, auto_merge and stage are identical.
      park_on_gate!(ctx, "ci_passed", false)
      pid = boot_router!(ctx.task, ctx.assignee)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      refute_received {:runtime_event, %{event_type: "execution.awaiting_human_action"}}
      assert blocker_count(ctx.task.id) == before_blockers + 1

      reloaded = Tasks.get_task_record(ctx.task.id)
      assert reloaded.status == "blocked"
      refute Map.has_key?(reloaded.metadata, "awaiting_human_action")
    end

    test "CONTROL: auto_merge:true makes pr_merged agent-passable, so it fires", ctx do
      park_on_gate!(ctx, "pr_merged", true)
      pid = boot_router!(ctx.task, ctx.assignee)

      before_blockers = blocker_count(ctx.task.id)
      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      refute_received {:runtime_event, %{event_type: "execution.awaiting_human_action"}}
      assert blocker_count(ctx.task.id) == before_blockers + 1
    end

    test "a second :check_safety_net after a park is a silent no-op", ctx do
      park_on_gate!(ctx, "pr_merged", false)
      pid = boot_router!(ctx.task, ctx.assignee)

      expire_safety_net_deadline!(ctx.task.id)
      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.awaiting_human_action"}}
      first = Tasks.get_task_record(ctx.task.id)
      notices_after_first = notice_count(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      refute_received {:runtime_event, %{event_type: "execution.awaiting_human_action"}}
      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert notice_count(ctx.task.id) == notices_after_first

      second = Tasks.get_task_record(ctx.task.id)
      # No double-stamp: the timestamp is the one written by the first pass.
      assert second.metadata["awaiting_human_action_at"] ==
               first.metadata["awaiting_human_action_at"]
    end

    test "leaving deploying clears the stamp and leaves the other JSONB keys", ctx do
      park_on_gate!(ctx, "pr_merged", false)
      pid = boot_router!(ctx.task, ctx.assignee)

      expire_safety_net_deadline!(ctx.task.id)
      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      stamped = Tasks.get_task_record(ctx.task.id)
      assert stamped.metadata["awaiting_human_action"] == "merge"

      {:ok, moved} = Tasks.transition_task_status(stamped, "done")

      refute Map.has_key?(moved.metadata, "awaiting_human_action")
      refute Map.has_key?(moved.metadata, "awaiting_human_action_at")
      assert moved.metadata["blocked_reason"] == "a pre-existing reason"
      assert moved.metadata["unmet_dependencies"] == ["pre-existing-dep"]
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Reshape the shared fixture into a task parked in `deploying` on a deploy
  # stage whose ONLY open validation is `kind`. Runs before the router boots
  # so the lease is armed with the `deploying` stage kind.
  defp park_on_gate!(ctx, kind, auto_merge) do
    Enum.each(ctx.validations, &Repo.delete!/1)
    {:ok, _} = Tasks.create_validation(%{stage_id: ctx.stage.id, kind: kind})

    {:ok, _} =
      ctx.stage
      |> Ecto.Changeset.change(%{name: "deploy", description: "deploy — ship it"})
      |> Repo.update()

    {:ok, task} =
      ctx.task
      |> Ecto.Changeset.change(%{
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => auto_merge}},
        metadata: %{
          "blocked_reason" => "a pre-existing reason",
          "unmet_dependencies" => ["pre-existing-dep"]
        }
      })
      |> Repo.update()

    {:ok, task} = Tasks.transition_task_status(task, "in_progress")
    {:ok, task} = Tasks.transition_task_status(task, "deploying")
    assert task.status == "deploying"
    :ok
  end

  defp notice_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.count(&String.contains?(&1.content, "Waiting on a human merge"))
  end

  # The park must not post the accusing blocker in ANY wording, so this
  # checks the prefix the blocker path hardcodes rather than its sentence.
  defp needs_human_posted?(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.any?(&String.contains?(&1.content, "Blocker reported: "))
  end

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
