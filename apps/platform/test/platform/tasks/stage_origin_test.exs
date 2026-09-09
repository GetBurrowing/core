defmodule Platform.Tasks.StageOriginTest do
  @moduledoc """
  Task 01a0588e stage 1. `stages.origin` is a STRUCTURAL marker of who wrote
  a stage, and the whole point of the column is that it is not prose.

  The prose probe below is the centre of this file. The engine's synthesized
  stage is called "Task-level review" and its description opens "Synthesized
  by the plan engine…". Both are template copy. Any classifier keyed to
  either fails OPEN the first time someone rewords the template — it would
  read the engine's own stage as planner-authored and admit exactly the
  stageless plans the marker exists to refuse. So the probe REWORDS the
  description and RENAMES the stage, then asserts classification is
  unchanged, and additionally asserts that a prose-keyed classifier gets the
  fixture WRONG. That second assertion is what keeps the fixture adversarial:
  soften the reword and the test goes red.
  """
  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Federation.ToolSurface

  defp project do
    {:ok, project} = Tasks.create_project(%{name: "Origin #{System.unique_integer([:positive])}"})
    project
  end

  defp task(title \\ "Origin task") do
    {:ok, task} = Tasks.create_task(%{project_id: project().id, title: title})
    task
  end

  defp e2e_case(behavior) do
    %{
      "kind" => "e2e_behavior",
      "evaluation_payload" => %{
        "setup" => "seed a #{behavior}",
        "actions" => "open #{behavior}",
        "expected" => "#{behavior} renders"
      }
    }
  end

  defp authored_stages do
    [
      %{
        "name" => "Add the marker",
        "description" => "Add it",
        "position" => 1,
        "validations" => [%{"kind" => "test_pass"}, e2e_case("marker persists")]
      },
      %{
        "name" => "Carry it through the writers",
        "description" => "Carry it",
        "position" => 2,
        "validations" => [%{"kind" => "lint_pass"}]
      }
    ]
  end

  # The tempting wrong implementation, written out so the fixture can be
  # asserted against it. NOT production code — it exists only to be proven
  # wrong on this fixture.
  defp prose_keyed_synthesized?(%Stage{name: name, description: description}) do
    String.contains?(String.downcase(name || ""), "task-level review") or
      String.contains?(description || "", "Synthesized by the plan engine")
  end

  describe "origin vocabulary" do
    test "is a closed set of authored and synthesized" do
      assert Stage.origins() == ~w(authored synthesized)
    end

    test "the changeset refuses an origin outside it" do
      {:ok, plan} = Tasks.create_plan(%{task_id: task().id})

      assert {:error, changeset} =
               Tasks.create_stage(%{
                 plan_id: plan.id,
                 position: 1,
                 name: "Bogus",
                 origin: "engine"
               })

      assert {"is invalid", _} = changeset.errors[:origin]
    end

    test "a stage written without an origin reads as authored" do
      {:ok, plan} = Tasks.create_plan(%{task_id: task().id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Plain"})

      assert stage.origin == "authored"
      assert PlanEngine.authored_stage?(stage)
    end
  end

  describe "plan_create marks the engine's stage and only the engine's stage" do
    test "two authored stages plus e2e cases produce three rows, exactly one synthesized" do
      t = task()

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => t.id, "stages" => authored_stages()},
          %{}
        )

      stages = Tasks.list_stages(plan.id)
      assert length(stages) == 3

      assert Enum.map(stages, & &1.origin) == ~w(authored authored synthesized)
      assert Enum.count(stages, &(&1.origin == "synthesized")) == 1
      assert Tasks.authored_stage_count(plan.id) == 2

      # And the %Plan{}-with-loaded-stages clause agrees with the query one.
      loaded = Platform.Repo.get!(Platform.Tasks.Plan, plan.id) |> Platform.Repo.preload(:stages)
      assert Tasks.authored_stage_count(loaded) == 2
    end
  end

  describe "THE PROSE PROBE" do
    test "reworded description and renamed stage do not change classification" do
      # The engine's OWN synthesized stage map, taken from the real routing
      # path rather than hand-copied, then stripped of every prose tell.
      routed = PlanEngine.route_e2e_behavior_validations(authored_stages())
      assert length(routed) == 3

      disguised =
        List.update_at(routed, 2, fn stage ->
          stage
          |> Map.put("name", "Wrap-up")
          |> Map.put(
            "description",
            "The reviewer walks the behavioural script and dispositions the case."
          )
        end)

      # ...and, in the other direction, an authored stage wearing the
      # template's clothes. A prose-keyed classifier calls this one the
      # engine's.
      disguised =
        List.update_at(disguised, 0, fn stage ->
          stage
          |> Map.put("name", "Task-level review of the marker")
          |> Map.put(
            "description",
            "Synthesized by the plan engine to host the planner-authored e2e_behavior validation."
          )
        end)

      {:ok, plan} = Tasks.create_plan(%{task_id: task().id})
      {:ok, _} = Tasks.replace_plan_stages(plan, disguised)

      stages = Tasks.list_stages(plan.id)

      # Classification by ORIGIN — unchanged by any of the above.
      assert Enum.map(stages, & &1.origin) == ~w(authored authored synthesized)
      assert Tasks.authored_stage_count(plan.id) == 2
      assert Enum.map(stages, &PlanEngine.authored_stage?/1) == [true, true, false]

      # Classification by PROSE — wrong on both stages we disguised. This is
      # the assertion that keeps the fixture adversarial: if someone softens
      # the reword above, these go red before the origin assertions do, and
      # an implementation keyed to name or description fails the assertions
      # above on exactly this input.
      assert Enum.map(stages, &prose_keyed_synthesized?/1) == [true, false, false]

      refute Enum.map(stages, &prose_keyed_synthesized?/1) ==
               Enum.map(stages, &(&1.origin == "synthesized"))
    end

    test "authored_stage_count is blind to a plan whose every stage reads like the engine's" do
      stages =
        Enum.map(1..2, fn i ->
          %{
            "name" => "Task-level review #{i}",
            "description" => "Synthesized by the plan engine to host something.",
            "position" => i
          }
        end)

      {:ok, plan} = Tasks.create_plan(%{task_id: task().id})
      {:ok, _} = Tasks.replace_plan_stages(plan, stages)

      assert Tasks.authored_stage_count(plan.id) == 2
      assert Enum.all?(Tasks.list_stages(plan.id), &prose_keyed_synthesized?/1)
    end
  end

  describe "a planner cannot set origin" do
    test "plan_create ignores a planner-supplied synthesized origin" do
      t = task()

      forged = Enum.map(authored_stages(), &Map.put(&1, "origin", "synthesized"))

      {:ok, plan} =
        ToolSurface.execute("plan_create", %{"task_id" => t.id, "stages" => forged}, %{})

      stages = Tasks.list_stages(plan.id)
      assert Enum.map(stages, & &1.origin) == ~w(authored authored synthesized)
      assert Tasks.authored_stage_count(plan.id) == 2
    end

    test "plan_update ignores a planner-supplied synthesized origin" do
      t = task()

      {:ok, plan} =
        ToolSurface.execute(
          "plan_create",
          %{"task_id" => t.id, "stages" => authored_stages()},
          %{}
        )

      forged =
        authored_stages()
        |> Enum.map(&Map.put(&1, "origin", "synthesized"))

      {:ok, _} =
        ToolSurface.execute(
          "plan_update",
          %{"plan_id" => plan.id, "stages" => forged},
          %{}
        )

      stages = Tasks.list_stages(plan.id)
      assert Enum.map(stages, & &1.origin) == ~w(authored authored synthesized)
      assert Tasks.authored_stage_count(plan.id) == 2
    end

    test "atom-keyed origin is stripped too" do
      assert PlanEngine.strip_planner_origin([%{"name" => "x", :origin => "synthesized"}]) ==
               [%{"name" => "x"}]
    end
  end

  describe "the remediation stage the engine opens" do
    test "is marked synthesized" do
      {:ok, plan} = Tasks.create_plan(%{task_id: task().id})
      {:ok, _impl} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Land it"})

      {:ok, gate} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Task-level review",
          status: "failed",
          origin: "synthesized"
        })

      {:ok, e2e} =
        Tasks.create_validation(%{
          stage_id: gate.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "seed it",
            "actions" => "open it",
            "expected" => "it renders"
          }
        })

      e2e
      |> Platform.Tasks.Validation.changeset(%{
        status: "failed",
        evidence: %{"finding" => "the script did not pass"},
        evaluated_by: "review_gate",
        evaluated_at: DateTime.utc_now()
      })
      |> Platform.Repo.update!()

      {:ok, remediation} = PlanEngine.open_remediation_stage(gate, "the script did not pass")

      assert remediation.name == PlanEngine.remediation_stage_name()
      assert remediation.origin == "synthesized"
      refute PlanEngine.authored_stage?(remediation)

      # The plan now has ONE authored stage: neither engine-emitted stage
      # inflates the count.
      assert Tasks.authored_stage_count(plan.id) == 1
    end
  end
end
