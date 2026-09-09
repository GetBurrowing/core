defmodule Platform.Tasks.SubmitPlanAuthoredStageGuardTest do
  @moduledoc """
  Task 01a0588e stage 2. `Tasks.submit_plan_for_review/1` refuses a draft
  that carries no planner-authored stage.

  WHY THE GUARD EXISTS. Four plans reached the `architecture.review_plan`
  gate with zero stages and all four were recorded `passed` — not because
  an architect agreed, but because `plan_architecture_verdict` cannot
  express a well-formed REJECT for a stageless plan: every finding must
  carry a `stage_id` belonging to the plan, and there is none. The gate
  could only say yes. So the plan must never reach the gate.

  WHY THREE CASES, and what each one kills:

    * REFUSE / zero stages is the headline, and on its own it is passed by
      a guard that refuses EVERYTHING.
    * SUCCEED / one authored stage kills that refuse-everything guard.
    * REFUSE / only-synthesized kills the naive `stages != []` guard — a
      plan whose single stage is the engine's synthesized task-level review
      host has a non-zero stage count and still contains no work. Delete
      this case and `length(stages) > 0` passes the whole file.

  The only-synthesized fixture is built BY THE ENGINE: a real `plan_create`
  synthesizes the review host from e2e cases, and then the authored stages
  are deleted. The surviving row's `origin` is the one the engine itself
  wrote — no test hand-sets `origin` on an otherwise authored stage, which
  would prove only that the guard reads a value the test invented.

  KNOWN NON-REACHABLE SHAPE, checked rather than assumed. Stage 1 marked
  `origin: "synthesized"` on the e2e review host and on the remediation
  stage, but NOT on `DeployStageBuilder`'s stages, which are engine-built
  and still read `"authored"`. A plan of "deploy stage + review host" would
  therefore count as one authored stage and be admitted here. It cannot
  arise at submit time: deploy stages are injected by
  `PlanEngine.maybe_inject_deploy_or_complete/2`, which runs when the LAST
  implementation stage passes — long after the plan left `draft` — and the
  only other builder (`build_deploy_plan/1`) is called from the TaskRouter
  on the same post-execution path. A draft has no deploy stage to inflate
  its count with. If that ever changes, this guard needs stage 1's marking
  widened, not a workaround here.

  And the stage-1 prose probe must still hold THROUGH the guard: rewording
  the synthesized stage's name and description does not make it authored,
  so a reworded synthesized-only plan is still refused.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stage}

  defp task do
    {:ok, project} =
      Tasks.create_project(%{name: "Guard #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Guard task"})
    task
  end

  defp e2e_case do
    %{
      "kind" => "e2e_behavior",
      "evaluation_payload" => %{
        "setup" => "seed a draft",
        "actions" => "submit it",
        "expected" => "it is refused"
      }
    }
  end

  defp authored_stage(name, position, validations \\ [%{"kind" => "test_pass"}]) do
    %{
      "name" => name,
      "description" => "does #{name}",
      "position" => position,
      "validations" => validations
    }
  end

  # A draft plan with no stages at all.
  defp stageless_plan do
    {:ok, plan} = Tasks.create_plan(%{task_id: task().id})
    assert Tasks.list_stages(plan.id) == []
    plan
  end

  # A draft plan whose ONLY stage is the engine's own synthesized review
  # host. Built through `plan_create` so the surviving row is engine-written
  # verbatim, then the authored stages are removed.
  defp synthesized_only_plan do
    {:ok, plan} =
      ToolSurface.execute(
        "plan_create",
        %{
          "task_id" => task().id,
          "stages" => [authored_stage("Implement", 1, [%{"kind" => "test_pass"}, e2e_case()])]
        },
        %{}
      )

    stages = Tasks.list_stages(plan.id)
    assert Enum.count(stages, &(&1.origin == "synthesized")) == 1

    for stage <- stages, stage.origin != "synthesized", do: Repo.delete!(stage)

    remaining = Tasks.list_stages(plan.id)
    assert length(remaining) == 1
    assert hd(remaining).origin == "synthesized"

    {Repo.get!(Plan, plan.id), hd(remaining)}
  end

  defp assert_refused(plan) do
    assert {:error, :no_authored_stages} = Tasks.submit_plan_for_review(plan)

    # NOTHING WAS WRITTEN. The draft survives so the author can fix it in
    # place with plan_update, and no gate was opened — which is the entire
    # point, since an opened gate on a stageless plan can only pass.
    reloaded = Repo.get!(Plan, plan.id)
    assert reloaded.status == "draft"
    assert Tasks.architecture_gate(reloaded) == :none
    refute Tasks.architecture_gate_open?(reloaded)
    assert is_nil(reloaded.architecture_verdict)

    reloaded
  end

  describe "REFUSE — a plan with no stages at all" do
    test "is refused, stays draft, and opens no architecture gate" do
      assert_refused(stageless_plan())
    end

    test "the MCP envelope is recoverable and names the omission" do
      plan = stageless_plan()

      assert {:error, envelope} = ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert envelope.recoverable == true
      # No code taxonomy is invented for plan_submit.
      refute Map.has_key?(envelope, :code)

      error = envelope.error
      assert error =~ "no planner-authored implementation stage"

      # THE OMISSION IS NAMED, including the non-obvious half: that the
      # engine's synthesized review stage does not count as work.
      assert error =~ "synthesized task-level review stage counts as none"

      assert envelope.suggestion =~ "plan_update"
      assert envelope.suggestion =~ "plan_reject"

      # And the refusal did not write.
      assert Repo.get!(Plan, plan.id).status == "draft"
    end
  end

  describe "REFUSE — a plan whose only stage is the engine's synthesized one" do
    test "is refused even though its stage count is not zero" do
      {plan, stage} = synthesized_only_plan()

      # The precondition that makes this case load-bearing: a naive
      # `stages != []` guard would ADMIT this plan.
      assert length(Tasks.list_stages(plan.id)) == 1
      assert Tasks.authored_stage_count(plan.id) == 0
      assert stage.origin == "synthesized"

      assert_refused(plan)
    end

    test "rewording the synthesized stage's name and description does not make it authored" do
      {plan, stage} = synthesized_only_plan()

      # The stage-1 prose probe, carried through the guard. A classifier
      # keyed to the template copy ("Task-level review" / "Synthesized by
      # the plan engine…") would read this row as planner-authored and
      # admit the plan — failing OPEN, which is the same failure class as
      # the bug the guard exists to fix.
      {:ok, reworded} =
        stage
        |> Stage.changeset(%{
          name: "Whole-task behavioural sign-off",
          description: "The reviewer walks the scripted behaviour and dispositions the case."
        })
        |> Repo.update()

      refute reworded.name =~ "Task-level review"
      refute reworded.description =~ "Synthesized by the plan engine"
      assert reworded.origin == "synthesized"

      assert Tasks.authored_stage_count(plan.id) == 0
      assert_refused(plan)
    end
  end

  describe "SUCCEED — a plan carrying authored work" do
    test "one authored stage submits" do
      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => task().id, "stages" => [authored_stage("Implement", 1)]},
          %{}
        )

      plan = Repo.get!(Plan, plan.id)
      assert Tasks.authored_stage_count(plan.id) == 1

      assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      assert Repo.get!(Plan, plan.id).status == "pending_review"
    end

    test "one authored plus the engine's synthesized stage submits" do
      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task().id,
            "stages" => [
              authored_stage("Implement", 1, [%{"kind" => "test_pass"}, e2e_case()])
            ]
          },
          %{}
        )

      stages = Tasks.list_stages(plan.id)
      assert Enum.map(stages, & &1.origin) == ~w(authored synthesized)
      assert Tasks.authored_stage_count(plan.id) == 1

      plan = Repo.get!(Plan, plan.id)
      assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
    end

    test "the MCP tool returns the serialized plan, not an envelope" do
      {:ok, created} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => task().id, "stages" => [authored_stage("Implement", 1)]},
          %{}
        )

      assert {:ok, submitted} =
               ToolSurface.execute("plan_submit", %{"plan_id" => created.id}, %{})

      assert submitted.status == "pending_review"
    end
  end

  describe "the guard runs before the status check, not instead of it" do
    test "a non-draft plan still reports :invalid_transition" do
      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => task().id, "stages" => [authored_stage("Implement", 1)]},
          %{}
        )

      plan = Repo.get!(Plan, plan.id)
      assert {:ok, submitted} = Tasks.submit_plan_for_review(plan)
      assert {:error, :invalid_transition} = Tasks.submit_plan_for_review(submitted)
    end

    test "a stageless plan that is already pending_review reports :invalid_transition" do
      # The status clause owns statuses; the authored-stage guard owns
      # drafts. A plan that got past the guard before it existed must not
      # start reporting :no_authored_stages instead of :invalid_transition.
      plan = stageless_plan()

      {:ok, submitted} =
        plan |> Ecto.Changeset.change(%{status: "pending_review"}) |> Repo.update()

      assert {:error, :invalid_transition} = Tasks.submit_plan_for_review(submitted)
    end
  end

  describe "staleness" do
    test "a struct preloaded before its stages were deleted is still refused" do
      {plan_id, stale} = stale_preloaded_plan()

      # `stale.stages` still lists the authored stage that is gone from the
      # database. The guard counts by ID, so it does not pass on it.
      assert Enum.any?(stale.stages, &(&1.origin == "authored"))
      assert Tasks.authored_stage_count(plan_id) == 0

      assert {:error, :no_authored_stages} = Tasks.submit_plan_for_review(stale)
      assert Repo.get!(Plan, plan_id).status == "draft"
    end
  end

  defp stale_preloaded_plan do
    {:ok, plan} =
      ToolSurface.execute(
        "plan_create",
        %{"task_id" => task().id, "stages" => [authored_stage("Implement", 1)]},
        %{}
      )

    stale = Plan |> Repo.get!(plan.id) |> Repo.preload(:stages)

    for stage <- Tasks.list_stages(plan.id), do: Repo.delete!(stage)

    {plan.id, stale}
  end
end
