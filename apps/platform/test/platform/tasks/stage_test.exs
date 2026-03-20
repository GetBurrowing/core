defmodule Platform.Tasks.StageTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Stage Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stage Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    %{plan: plan}
  end

  describe "create_stage/1" do
    test "creates a stage with valid attrs", %{plan: plan} do
      assert {:ok, stage} =
               Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      assert stage.name == "Build"
      assert stage.position == 1
      assert stage.status == "pending"
    end

    test "fails without required fields" do
      assert {:error, changeset} = Tasks.create_stage(%{})
      errors = errors_on(changeset)
      assert errors[:plan_id]
      assert errors[:position]
      assert errors[:name]
    end
  end

  describe "list_stages/1" do
    test "returns stages ordered by position", %{plan: plan} do
      {:ok, _} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})
      {:ok, _} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      stages = Tasks.list_stages(plan.id)
      assert Enum.map(stages, & &1.name) == ["Build", "Test"]
    end
  end

  describe "transition_stage/2" do
    test "pending → running → passed", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

      assert {:ok, stage} = Tasks.transition_stage(stage, "running")
      assert stage.status == "running"
      assert stage.started_at != nil

      assert {:ok, stage} = Tasks.transition_stage(stage, "passed")
      assert stage.status == "passed"
      assert stage.completed_at != nil
    end

    test "running → failed → running (retry)", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, stage} = Tasks.transition_stage(stage, "running")
      {:ok, stage} = Tasks.transition_stage(stage, "failed")
      assert stage.status == "failed"

      assert {:ok, stage} = Tasks.transition_stage(stage, "running")
      assert stage.status == "running"
    end

    test "pending → skipped", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      assert {:ok, stage} = Tasks.transition_stage(stage, "skipped")
      assert stage.status == "skipped"
    end

    test "rejects invalid transitions", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      assert {:error, :invalid_transition} = Tasks.transition_stage(stage, "passed")
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
