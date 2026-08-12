defmodule Platform.Orchestration.TaskRouterReviewRoundBoundTest do
  @moduledoc """
  The review gate → `in_progress` loop is bounded at three rounds, and only a
  round that actually judged the FEATURE spends one (task 019ff788 stage 3).

  ## Why there are two fixtures and why neither alone proves anything

  A bounce path that ignored the `could_not_evaluate` distinction entirely —
  increment on every failed gate, full stop — passes the three-round test on
  its own. A path that never incremented at all passes the un-runnable test
  on its own. Only the pair separates them, so the two `describe` blocks
  below are one assertion in two halves.

  The three-round half asserts the COUNTER AT EVERY ROUND, not only the
  terminal routing. An implementation that jumped straight to re-planning on
  the first failure, or that re-planned on a counter it never wrote, reaches
  the same endpoint from a different mechanism; reading the counter after
  each round is what tells them apart.

  The un-runnable half asserts three things together: the counter did NOT
  move, a blocker WAS raised, and the task did NOT re-plan. Dropping any one
  of them admits an implementation that satisfies the other two — silently
  swallowing the round with no blocker is exactly the "quiet degradation"
  shape this fixture exists to catch.

  No `Process.sleep`. The barrier is `TaskRouter.current_status/1`, a
  `GenServer.call` answered only once every queued message is handled.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.ReviewDisposition
  alias Platform.Tasks.Stage

  @e2e_payload %{
    "setup" => "A task sits at its behavioural review gate.",
    "actions" => "Fail the gate.",
    "expected" => "The bounce is bounded."
  }

  @genuine_evidence %{
    "observed" => "The button does nothing.",
    "expected" => "The button submits the form.",
    "diagnostics" => "no LiveView event fired"
  }

  @unrunnable_evidence %{
    "disposition" => "could_not_evaluate",
    "reason" => "dev server would not boot: migration lock held by another run",
    "diagnostics" => "mix phx.server exited 1"
  }

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Review Round Bound Project",
        repo_url: "https://github.com/test/review-round-bound"
      })

    %{project: project}
  end

  describe "three genuine gate failures route the task to re-planning" do
    test "the counter moves once per round and round 3 re-plans", %{project: project} do
      %{task: task, plan: plan, gates: [g1, g2, g3]} = gated_task(project)
      start_router!(task)

      assert Tasks.get_task_record(task.id).review_round_count == 0

      fail_gate(task, g1, @genuine_evidence)

      assert Tasks.get_task_record(task.id).review_round_count == 1,
             "the first genuine gate failure must spend exactly one round"

      assert Tasks.get_task_record(task.id).status == "in_progress"

      fail_gate(task, g2, @genuine_evidence)

      assert Tasks.get_task_record(task.id).review_round_count == 2
      assert Tasks.get_task_record(task.id).status == "in_progress"

      fail_gate(task, g3, @genuine_evidence)

      # The endpoint — and the counter reading that says the endpoint was
      # reached by counting rather than by some other trigger.
      assert Tasks.get_task_record(task.id).review_round_count == 3
      assert Tasks.get_task_record(task.id).review_round_count == Tasks.max_review_rounds()

      assert Tasks.get_task_record(task.id).status == "planning",
             "round #{Tasks.max_review_rounds()} must route to re-planning, not back to in_progress"

      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status == "superseded",
             "re-planning means the failed plan is superseded so the planner authors a new one"
    end

    test "approving a plan returns the task a full allowance", %{project: project} do
      %{task: task} = gated_task(project)

      {:ok, spent, 1} = Tasks.spend_review_round(task)
      assert spent.review_round_count == 1

      {:ok, replan} = Tasks.create_plan(%{task_id: task.id, status: "draft"})

      replan =
        replan
        |> Platform.Tasks.Plan.changeset(%{status: "pending_review"})
        |> Platform.Repo.update!()

      {:ok, _approved} = Tasks.approve_plan(replan, "system:auto", auto: true)

      assert Tasks.get_task_record(task.id).review_round_count == 0,
             "rounds spent against the old plan must not be charged to the new one"
    end
  end

  describe "a gate that could not be RUN spends nothing and raises a blocker" do
    test "counter unmoved, blocker raised, task not re-planned", %{project: project} do
      %{task: task, plan: plan, gates: [g1, _g2, _g3]} = gated_task(project)
      start_router!(task)

      fail_gate(task, g1, @unrunnable_evidence)

      reloaded = Tasks.get_task_record(task.id)

      assert reloaded.review_round_count == 0,
             "an un-runnable review must not spend a round — otherwise a broken " <>
               "environment re-plans a feature that was never wrong"

      assert reloaded.status == "in_progress",
             "the un-runnable path bounces for a retry; it must not re-plan"

      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status != "superseded"

      blockers =
        Platform.Repo.all(
          from(e in RuntimeEvent,
            where: e.task_id == ^task.id and e.event_type == "execution.blocked"
          )
        )

      assert [blocker] = blockers

      assert blocker.payload["description"] =~ "could not be evaluated",
             "the blocker must name the condition, not just exist"

      assert blocker.payload["description"] =~ "would not boot",
             "the reviewer's reason must reach the human who has to fix it"
    end

    test "three un-runnable rounds still never re-plan", %{project: project} do
      # The direction control for the counter half: the same three rounds that
      # re-plan when genuine must be survivable indefinitely when un-runnable.
      %{task: task, gates: gates} = gated_task(project)
      start_router!(task)

      Enum.each(gates, fn gate -> fail_gate(task, gate, @unrunnable_evidence) end)

      assert Tasks.get_task_record(task.id).review_round_count == 0
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "the marker without a reason is counted as a genuine failure", %{project: project} do
      # The free-pass hole: if a bare marker suppressed the round, the bound
      # would be unreachable by anyone who reached for it out of habit.
      %{task: task, gates: [g1, _, _]} = gated_task(project)
      start_router!(task)

      fail_gate(task, g1, %{"disposition" => ReviewDisposition.marker()})

      assert Tasks.get_task_record(task.id).review_round_count == 1
    end
  end

  describe "ReviewDisposition.classify_all/1" do
    test "one genuine verdict in a mixed set spends the round" do
      mixed = [
        %{evidence: @unrunnable_evidence},
        %{evidence: @genuine_evidence}
      ]

      assert ReviewDisposition.classify_all(mixed) == :genuine

      assert {:could_not_evaluate, _} =
               ReviewDisposition.classify_all([%{evidence: @unrunnable_evidence}])
    end

    test "reads atom-keyed evidence as well as string-keyed" do
      # An evidence map written in-process still holds atom keys; one read
      # back from Postgres holds strings. Both must classify the same.
      atoms = %{disposition: "could_not_evaluate", reason: "no dev server"}
      assert {:could_not_evaluate, "no dev server"} = ReviewDisposition.classify(atoms)
    end

    test "a blank reason is malformed, not a free pass" do
      assert ReviewDisposition.classify(%{"disposition" => "could_not_evaluate"}) == :malformed

      assert ReviewDisposition.classify(%{
               "disposition" => "could_not_evaluate",
               "reason" => "   "
             }) == :malformed
    end

    test "an empty failed set refuses to classify rather than defaulting to genuine" do
      # A failed gate stage always has a failed validation, so an empty list
      # is a READ that outran the writer's commit, not evidence about the
      # feature. It used to answer `:genuine`, which is how a read-timing
      # race turned into a silent policy violation. The safe direction is to
      # spend no round and raise a blocker.
      assert {:could_not_evaluate, reason} = ReviewDisposition.classify_all([])

      assert reason =~ "no failed validation was readable",
             "the reason must name the READ, so a human is not sent to debug the feature"
    end
  end

  describe "the empty failed-validation set is the read-too-early backstop" do
    test "a failed gate whose validations still read pending spends no round and blocks",
         %{project: project} do
      # This reproduces what the router SAW during the race, without racing:
      # the stage row says `failed` while its validation still reads
      # `pending`, so `failed_validations_for_stage/1` returns []. The fix in
      # `PlanEngine` means the router is no longer handed this state by the
      # engine; this asserts the backstop holds if anything else ever does.
      %{task: task, plan: plan, gates: [g1, _, _]} = gated_task(project)
      start_router!(task)

      {:ok, running} = PlanEngine.start_stage(g1.id)
      barrier(task)

      {:ok, failed} = Tasks.transition_stage(running, "failed")

      assert [%{status: "pending"}] = Tasks.list_validations(g1.id),
             "the fixture is only meaningful while the validation still reads pending"

      Tasks.broadcast_board({:stage_transitioned, failed})
      barrier(task)

      reloaded = Tasks.get_task_record(task.id)

      assert reloaded.review_round_count == 0,
             "a round read too early to be judged must not be charged to the bound"

      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status != "superseded"

      blockers =
        Platform.Repo.all(
          from(e in RuntimeEvent,
            where: e.task_id == ^task.id and e.event_type == "execution.blocked"
          )
        )

      assert [blocker] = blockers

      assert blocker.payload["description"] =~ "no failed validation was readable",
             "swallowing the round with no blocker is the quiet degradation this " <>
               "backstop exists to prevent"
    end

    test "direction control: a GENUINE failure read in full still spends its round",
         %{project: project} do
      # Neither half proves anything alone. If the backstop above leaked into
      # the ordinary path, every genuine failure would stop spending rounds
      # and the bound would be unreachable.
      %{task: task, gates: [g1, _, _]} = gated_task(project)
      start_router!(task)

      fail_gate(task, g1, @genuine_evidence)

      assert Tasks.get_task_record(task.id).review_round_count == 1
      assert Tasks.get_task_record(task.id).status == "in_progress"

      assert Platform.Repo.all(
               from(e in RuntimeEvent,
                 where: e.task_id == ^task.id and e.event_type == "execution.blocked"
               )
             ) == [],
             "a genuine verdict routes normally — it must not raise an un-runnable blocker"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # An `in_progress` task with an approved plan: one settled implementation
  # stage and THREE pending review gates, each carrying its own
  # `e2e_behavior` validation. Three gates rather than one re-opened gate
  # because that is the shape the engine actually produces on a bounce — the
  # router opens the next pending stage after each failure.
  defp gated_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Bounded review task",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(build, "running")
    {:ok, _passed} = Tasks.transition_stage(running, "passed")

    gates =
      Enum.map(2..4, fn position ->
        {:ok, gate} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: position,
            name: "Task-level review (round #{position - 1})"
          })

        {:ok, _validation} =
          Tasks.create_validation(%{
            stage_id: gate.id,
            kind: "e2e_behavior",
            evaluation_payload: @e2e_payload
          })

        gate
      end)

    %{task: task, plan: plan, gates: gates}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Run one review round against `gate` and fail it with `evidence`. The gate
  # may already be running — the router opens the next pending stage when it
  # bounces — so this starts it only when it is still pending.
  defp fail_gate(task, gate, evidence) do
    if Platform.Repo.get!(Stage, gate.id).status == "pending" do
      {:ok, _running} = PlanEngine.start_stage(gate.id)
    end

    barrier(task)

    [validation] = Tasks.list_validations(gate.id)

    {:ok, _failed} =
      PlanEngine.evaluate_validation(validation.id, %{
        status: "failed",
        evidence: evidence,
        evaluated_by: "test"
      })

    barrier(task)
    :ok
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

    barrier(task)

    pid
  end

  defp barrier(task), do: TaskRouter.current_status(task.id)
end
