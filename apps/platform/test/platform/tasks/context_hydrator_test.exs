defmodule Platform.Tasks.ContextHydratorTest do
  @moduledoc "Tests for Platform.Tasks.ContextHydrator — context cascade hydration."
  use Platform.DataCase, async: false

  alias Platform.Context
  alias Platform.Tasks
  alias Platform.Tasks.ContextHydrator

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_project(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{
            name: "Hydrator Project #{System.unique_integer([:positive])}",
            repo_url: "https://github.com/org/hydrator-test",
            tech_stack: %{"language" => "elixir", "framework" => "phoenix"},
            deploy_config: %{"target" => "fly"}
          },
          attrs
        )
      )

    project
  end

  defp create_epic(project, attrs \\ %{}) do
    {:ok, epic} =
      Tasks.create_epic(
        Map.merge(
          %{
            project_id: project.id,
            name: "Auth Epic",
            description: "Implement authentication",
            acceptance_criteria: "Users can log in and out"
          },
          attrs
        )
      )

    epic
  end

  defp create_task(project, epic \\ nil, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            epic_id: epic && epic.id,
            title: "Implement login",
            description: "Build the login flow",
            priority: "high",
            dependencies: [%{"task_id" => "dep-1", "type" => "blocks"}]
          },
          attrs
        )
      )

    task
  end

  defp create_approved_plan(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage1} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Code",
        description: "Write the code"
      })

    {:ok, stage2} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test", description: "Run tests"})

    {:ok, _v1} = Tasks.create_validation(%{stage_id: stage1.id, kind: "lint_pass"})
    {:ok, _v2} = Tasks.create_validation(%{stage_id: stage2.id, kind: "test_pass"})

    {:ok, plan} = Tasks.submit_plan_for_review(plan)
    {:ok, plan} = Tasks.approve_plan(plan, Ecto.UUID.generate())

    plan
  end

  defp snapshot_items(scope) do
    case Context.snapshot(scope) do
      {:ok, %{items: items}} -> items
      _ -> []
    end
  end

  defp item_map(items) do
    Map.new(items, fn item -> {item.key, item} end)
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  describe "hydrate_for_run/2 with full hierarchy" do
    test "hydrates project + epic + task + plan items" do
      project = create_project()
      epic = create_epic(project)
      task = create_task(project, epic)
      _plan = create_approved_plan(task)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Verify project-scoped items
      project_scope = %{project_id: project.id}
      project_items = snapshot_items(project_scope) |> item_map()

      assert project_items["project.name"].value == project.name
      assert project_items["project.repo_url"].value == project.repo_url
      assert project_items["project.name"].kind == :project_config

      # Verify epic-scoped items
      epic_scope = %{project_id: project.id, epic_id: epic.id}
      epic_items = snapshot_items(epic_scope) |> item_map()

      assert epic_items["epic.name"].value == epic.name
      assert epic_items["epic.description"].value == epic.description
      assert epic_items["epic.acceptance_criteria"].value == epic.acceptance_criteria
      assert epic_items["epic.name"].kind == :epic_context

      # Verify task-scoped items
      task_scope = %{project_id: project.id, epic_id: epic.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()

      assert task_items["task.title"].value == task.title
      assert task_items["task.description"].value == task.description
      assert task_items["task.priority"].value == "high"
      assert task_items["task.title"].kind == :task_description

      # Verify plan stage items in task scope
      assert task_items["plan.stage.1.title"].value == "Code"
      assert task_items["plan.stage.1.description"].value == "Write the code"
      assert task_items["plan.stage.2.title"].value == "Test"
      assert task_items["plan.stage.1.title"].kind == :task_metadata

      # Verify validations are serialized
      v1 = Jason.decode!(task_items["plan.stage.1.validations"].value)
      assert "lint_pass" in v1

      v2 = Jason.decode!(task_items["plan.stage.2.validations"].value)
      assert "test_pass" in v2
    end
  end

  describe "hydrate_for_run/2 without epic" do
    test "hydrates project + task directly (no epic session)" do
      project = create_project()
      task = create_task(project, nil)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Project items exist
      project_scope = %{project_id: project.id}
      project_items = snapshot_items(project_scope) |> item_map()
      assert project_items["project.name"].value == project.name

      # Task items exist (scope has nil epic_id)
      task_scope = %{project_id: project.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()
      assert task_items["task.title"].value == task.title
    end
  end

  describe "hydrate_for_run/2 without plan" do
    test "hydrates project + epic + task context only" do
      project = create_project()
      epic = create_epic(project)
      task = create_task(project, epic)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Task items exist but no plan items
      task_scope = %{project_id: project.id, epic_id: epic.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()

      assert task_items["task.title"].value == task.title
      refute Map.has_key?(task_items, "plan.stage.1.title")
    end
  end

  describe "hydrate_for_run/2 error cases" do
    test "returns error for non-existent task" do
      assert {:error, :task_not_found} =
               ContextHydrator.hydrate_for_run(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "telemetry" do
    test "emits [:platform, :tasks, :context_hydrated] event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :tasks, :context_hydrated]
        ])

      project = create_project()
      task = create_task(project, nil)

      {:ok, _version} = ContextHydrator.hydrate_for_run(task.id, Ecto.UUID.generate())

      assert_received {[:platform, :tasks, :context_hydrated], ^ref, _measurements, metadata}
      assert metadata.task_id == task.id
    end
  end
end
