defmodule Platform.Orchestration.TaskRouterReviewGateStatusTest do
  @moduledoc """
  ADR 0029: the task must HOLD `in_review` WHILE its review gate runs, not
  after. Covers the `{:stage_transitioned, stage}` clause in
  `Platform.Orchestration.TaskRouter` (task 019ff788 stage 1).

  ## Why the assertions look the way they do

  The obvious assertion — "the task reads `in_review` after the gate stage
  starts" — is satisfiable by ANY later transition, and a test that reads the
  task row after plan completion passes on the pre-change code too. The
  observation here is instead `%State{task_status:}`, which `do_dispatch/2`
  writes from the task struct it read INSIDE the dispatch path. It is a
  snapshot taken at dispatch time and nothing that happens afterwards can
  rewrite it, so it distinguishes "transitioned before dispatch" (the
  requirement) from "transitioned at some point" (the vacuous version).

  The stage spec proposed asserting on the selected prompt template
  (`dispatch.review_e2e`) instead. That assertion is VACUOUS on this tree:
  `DispatchPhase.resolve/3` picks the slug from the stage's own pending
  validation kinds and consults `task.status` only as a last resort, so an
  `in_progress` task at an `e2e_behavior` stage already renders
  `dispatch.review_e2e` (see `dispatch_phase_test.exs`, "stale in_progress
  status on an e2e_behavior stage resolves to review_e2e"). Asserted here as a
  standing fact so a future change back to status-keyed selection is noticed.

  No `Process.sleep`. The barrier is `TaskRouter.current_status/1`, a
  `GenServer.call`, answered only once every queued message is handled.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  @e2e_payload %{
    "setup" => "A task sits at its review gate.",
    "actions" => "Read the task status the dispatch path saw.",
    "expected" => "It is in_review."
  }

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Review Gate Status Project",
        repo_url: "https://github.com/test/review-gate-status"
      })

    %{project: project}
  end

  describe "the review gate writes in_review before it dispatches" do
    test "the dispatch path reads in_review, not in_progress", %{project: project} do
      %{task: task, gate_stage: gate_stage} = gated_task(project)

      pid = start_router!(task)
      assert Tasks.get_task_record(task.id).status == "in_progress"

      {:ok, _running} = PlanEngine.start_stage(gate_stage.id)
      barrier(task)

      # THE anti-vacuity assertion. `task_status` is set only inside
      # `do_dispatch/2`, from the task it re-read there. On the pre-change code
      # this reads "in_progress" even though the row later becomes something
      # else, because the transition never happened before the dispatch.
      assert :sys.get_state(pid).task_status == "in_review",
             "the dispatch triggered by the review gate observed task status " <>
               "#{inspect(:sys.get_state(pid).task_status)}; ADR 0029 requires the task to " <>
               "already hold in_review when the gate dispatches"

      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    test "detects the gate structurally, not by stage name", %{project: project} do
      # `PlanEngine.attach_e2e_validations_to_review_stage/2` REUSES a
      # planner-authored stage whose name merely contains "review"/"validation"
      # instead of synthesizing "Task-level review", so a name-equality
      # predicate would miss those plans entirely.
      %{task: task, gate_stage: gate_stage} =
        gated_task(project, gate_name: "Adversarial behaviour sweep")

      pid = start_router!(task)

      {:ok, _running} = PlanEngine.start_stage(gate_stage.id)
      barrier(task)

      assert :sys.get_state(pid).task_status == "in_review"
      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    test "is a no-op for a task that is not in_progress", %{project: project} do
      %{task: task, gate_stage: gate_stage} = gated_task(project)
      {:ok, _blocked} = Tasks.transition_task(task, "blocked")

      pid = start_router!(task)

      log =
        capture_log(fn ->
          {:ok, _running} = PlanEngine.start_stage(gate_stage.id)
          barrier(task)
        end)

      # The guard refuses rather than forcing an illegal hop, and the router
      # survives either way.
      assert Process.alive?(pid)
      assert Tasks.get_task_record(task.id).status == "blocked"

      # The `in_progress` guard means the transition is never ATTEMPTED, so the
      # rejection warning must be absent too. Asserted at `warning` level
      # deliberately: the test logger is pinned to `:warning`, so a refute on
      # the success `Logger.info` would be vacuous.
      refute log =~ "failed to move task #{task.id} to in_review"
    end
  end

  describe "direction control: a plan with no e2e_behavior validations" do
    # UPDATED BY TASK 019ff788 STAGE 2, and the change of terminal state here is
    # the honest record of that stage's blast radius. Stage 1 left this path
    # completing straight to `deploying` from `in_progress`. Stage 2 narrowed
    # `PlanEngine.@deployable_statuses` to `~w(in_review)`, so an UNGATED plan —
    # one the planner gave no `e2e_behavior` validation, which is therefore
    # never reviewed — now completes WITHOUT a deploy stage and the task stays
    # at `in_progress`. That is the intended reading of the narrowing (deploy
    # follows review, and an unreviewed task does not ship) and it is loud, not
    # silent: the engine logs the refusal naming the task and the status.
    #
    # The direction control itself is unchanged and is still the point of this
    # test: with no gate stage, the dispatch snapshot must read `in_progress`
    # and `in_review` must never appear on the board.
    test "never touches in_review, and no longer deploys unreviewed", %{project: project} do
      %{task: task, stage: stage, validation: validation} = ungated_task(project)

      pid = start_router!(task)

      Tasks.subscribe_board()
      drain_status_changes(task.id)

      {:ok, _running} = PlanEngine.start_stage(stage.id)
      barrier(task)

      # No gate stage exists, so the dispatch must see the implementation
      # status. This is the half that would red if the transition fired on
      # every running stage rather than only on the gate.
      assert :sys.get_state(pid).task_status == "in_progress"

      log =
        capture_log(fn ->
          {:ok, _passed} =
            PlanEngine.evaluate_validation(validation.id, %{
              status: "passed",
              evaluated_by: "test"
            })

          barrier(task)
        end)

      assert Tasks.get_task_record(task.id).status == "in_progress",
             "an unreviewed task must not ship — stage 2 narrowed @deployable_statuses"

      plan = Tasks.get_plan(Tasks.current_plan(task.id).id)

      refute Enum.any?(
               plan.stages,
               &Platform.Tasks.DeployStageBuilder.deploy_stage_name?(&1.name)
             ),
             "no deploy stage may be injected for a plan that was never reviewed"

      assert log =~ "NOT injecting deploy stage for task #{task.id}",
             "the refusal must be loud — this branch is where a task would " <>
               "otherwise pile up looking like a clean completion"

      # `in_review` never appears — the direction control this test exists for.
      statuses = drain_status_changes(task.id)
      refute "in_review" in statuses
      refute "deploying" in statuses
    end
  end

  describe "template selection (standing fact, not the anti-vacuity assertion)" do
    test "review_e2e is already reachable from an in_progress task", %{project: project} do
      %{task: task, gate_stage: gate_stage} = gated_task(project)

      task_record = Tasks.get_task_record(task.id)

      phase =
        Platform.Orchestration.DispatchPhase.resolve(
          task_record,
          Tasks.current_plan(task.id),
          %{gate_stage | validations: Tasks.list_validations(gate_stage.id)}
        )

      # If this ever stops being true, the stage spec's proposed
      # template-based assertion becomes meaningful and this module's
      # `task_status` assertion is no longer the only honest observation.
      assert task_record.status == "in_progress"
      assert phase.slug == "dispatch.review_e2e"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # An `in_progress` task with an approved two-stage plan: a settled
  # implementation stage and a pending review gate carrying one `e2e_behavior`
  # validation.
  defp gated_task(project, opts \\ []) do
    gate_name = Keyword.get(opts, :gate_name, "Task-level review")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Review gate task",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(build, "running")
    {:ok, _passed} = Tasks.transition_stage(running, "passed")

    {:ok, gate_stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: gate_name})

    {:ok, _validation} =
      Tasks.create_validation(%{
        stage_id: gate_stage.id,
        kind: "e2e_behavior",
        evaluation_payload: @e2e_payload
      })

    %{task: task, plan: plan, gate_stage: gate_stage}
  end

  # An `in_progress` task whose single-stage plan carries no `e2e_behavior`
  # validation at all — the pre-change path, end to end.
  defp ungated_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Ungated task",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    %{task: task, plan: plan, stage: stage, validation: validation}
  end

  # ── helpers ────────────────────────────────────────────────────────────

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

    barrier(task)

    pid
  end

  defp barrier(task), do: TaskRouter.current_status(task.id)

  defp drain_status_changes(task_id, acc \\ []) do
    receive do
      {:task_updated, %{id: ^task_id, status: status}} ->
        drain_status_changes(task_id, [status | acc])

      _other ->
        drain_status_changes(task_id, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
