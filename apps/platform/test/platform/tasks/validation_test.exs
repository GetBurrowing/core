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

    test "accepts e2e_behavior with a complete evaluation_payload", %{stage: stage} do
      payload = %{
        "setup" => "create a fixture task with no plan",
        "actions" => "open the task detail panel and click Generate Plan",
        "expected" => "a plan v1 in pending_review appears within 30 seconds"
      }

      assert {:ok, v} =
               Tasks.create_validation(%{
                 stage_id: stage.id,
                 kind: "e2e_behavior",
                 evaluation_payload: payload
               })

      assert v.kind == "e2e_behavior"
      assert v.evaluation_payload == payload
    end

    test "accepts e2e_behavior with only setup/actions/expected (no failure_feedback)",
         %{stage: stage} do
      # v2: failure_feedback is no longer planner-supplied — the review agent
      # observes failures and posts them at review time. A payload with just
      # setup/actions/expected must validate.
      payload = %{
        "setup" => "create A and B",
        "actions" => "complete A; refresh B",
        "expected" => "B's blocked-by badge clears within 2 seconds"
      }

      assert {:ok, v} =
               Tasks.create_validation(%{
                 stage_id: stage.id,
                 kind: "e2e_behavior",
                 evaluation_payload: payload
               })

      assert v.evaluation_payload == payload
    end

    test "rejects e2e_behavior without an evaluation_payload", %{stage: stage} do
      assert {:error, changeset} =
               Tasks.create_validation(%{stage_id: stage.id, kind: "e2e_behavior"})

      assert errors_on(changeset)[:evaluation_payload]
    end

    test "rejects e2e_behavior with a payload missing required keys", %{stage: stage} do
      partial = %{"setup" => "x", "actions" => "y"}

      assert {:error, changeset} =
               Tasks.create_validation(%{
                 stage_id: stage.id,
                 kind: "e2e_behavior",
                 evaluation_payload: partial
               })

      message = errors_on(changeset)[:evaluation_payload] |> List.first()
      assert message =~ "missing required keys"
      assert message =~ "expected"
      # v2: failure_feedback is no longer required — the message must not
      # mention it as a missing key.
      refute message =~ "failure_feedback"
    end

    test "non-e2e kinds may omit evaluation_payload entirely", %{stage: stage} do
      assert {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      assert v.evaluation_payload == nil
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

    test "carries a manual_approval row's prior_rulings across the write", %{stage: stage} do
      prior = [%{"verdict" => "rejected", "note" => "invented sample note"}]

      {:ok, v} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "manual_approval",
          evidence: %{"prior_rulings" => prior}
        })

      assert {:ok, _} = Tasks.evaluate_validation(v.id, "passed", %{"summary" => "second look"})

      reloaded = Repo.get!(Tasks.Validation, v.id)
      assert reloaded.status == "passed"
      assert reloaded.evidence["summary"] == "second look"
      assert reloaded.evidence["prior_rulings"] == prior
      assert length(reloaded.evidence["prior_rulings"]) == 1
    end

    test "writes a test_pass row's evidence wholesale — no carry outside manual_approval",
         %{stage: stage} do
      {:ok, v} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "test_pass",
          evidence: %{"prior_rulings" => [%{"verdict" => "rejected", "note" => "stray"}]}
        })

      assert {:ok, _} = Tasks.evaluate_validation(v.id, "passed", %{"summary" => "second look"})

      reloaded = Repo.get!(Tasks.Validation, v.id)
      assert reloaded.evidence == %{"summary" => "second look"}
      refute Map.has_key?(reloaded.evidence, "prior_rulings")
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
