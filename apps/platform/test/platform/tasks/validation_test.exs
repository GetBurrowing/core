defmodule Platform.Tasks.ValidationTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Val Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Val Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
    %{stage: stage}
  end

  describe "create_validation/1" do
    test "creates with valid kind", %{stage: stage} do
      assert {:ok, validation} =
               Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      assert validation.kind == "test_pass"
      assert validation.status == "pending"
    end

    test "fails with invalid kind", %{stage: stage} do
      assert {:error, changeset} =
               Tasks.create_validation(%{stage_id: stage.id, kind: "invalid_kind"})

      errors = errors_on(changeset)
      assert errors[:kind]
    end

    test "fails without required fields" do
      assert {:error, changeset} = Tasks.create_validation(%{})
      errors = errors_on(changeset)
      assert errors[:stage_id]
      assert errors[:kind]
    end

    test "supports all valid kinds", %{stage: stage} do
      for kind <- ~w(ci_check lint_pass type_check test_pass code_review manual_approval) do
        assert {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: kind})
        assert v.kind == kind
      end
    end
  end

  describe "list_validations/1" do
    test "returns validations for a stage", %{stage: stage} do
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

      validations = Tasks.list_validations(stage.id)
      assert length(validations) == 2
    end
  end

  describe "evaluate_validation/3" do
    test "records pass with evidence", %{stage: stage} do
      {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      evidence = %{"output" => "42 tests, 0 failures"}

      assert {:ok, updated} = Tasks.evaluate_validation(v.id, "passed", evidence)
      assert updated.status == "passed"
      assert updated.evidence == evidence
      assert updated.evaluated_at != nil
    end

    test "records failure with evidence", %{stage: stage} do
      {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

      assert {:ok, updated} =
               Tasks.evaluate_validation(v.id, "failed", %{"errors" => ["unused var"]})

      assert updated.status == "failed"
    end

    test "returns error for missing validation" do
      assert {:error, :not_found} =
               Tasks.evaluate_validation(Ecto.UUID.generate(), "passed", %{})
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
