defmodule Platform.Tasks.TaskKindTest do
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  # These regressions fail on the unfixed base: Task.kinds/0, tasks.kind, the
  # composite index, and MCP kind inputs/outputs do not exist there.
  test "the taxonomy is small, explicit, and rejects unsupported values" do
    assert Task.kinds() == ~w(feature chore bug research ops)

    project = create_project()

    changeset =
      Task.changeset(%Task{}, %{
        project_id: project.id,
        title: "Unsupported kind",
        kind: "docs"
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).kind
  end

  test "task_create and task_update accept every kind through the tool surface" do
    project = create_project()

    created =
      for kind <- Task.kinds() do
        assert {:ok, task} =
                 ToolSurface.execute(
                   "task_create",
                   %{
                     "project_id" => project.id,
                     "title" => "Create #{kind}",
                     "kind" => kind
                   },
                   %{}
                 )

        assert task.kind == kind
        assert Tasks.get_task_record(task.id).kind == kind
        task
      end

    target = hd(created)

    for kind <- Task.kinds() do
      assert {:ok, updated} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => target.id, "kind" => kind},
                 %{}
               )

      assert updated.kind == kind
      assert Tasks.get_task_record(target.id).kind == kind
    end

    assert {:ok, fetched} = ToolSurface.execute("task_get", %{"task_id" => target.id}, %{})
    assert fetched.kind == "ops"

    assert {:ok, listed} =
             ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

    assert Enum.find(listed.tasks, &(&1.id == target.id)).kind == "ops"
  end

  test "an invalid tool-surface update is rejected without mutation" do
    project = create_project()

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Keep the kind", kind: "bug"})

    assert {:error, error} =
             ToolSurface.execute(
               "task_update",
               %{"task_id" => task.id, "kind" => "docs"},
               %{}
             )

    assert inspect(error) =~ "kind"
    assert Tasks.get_task_record(task.id).kind == "bug"
  end

  test "database default is non-null and existing-style inserts receive feature" do
    project = create_project()
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Default kind"})

    assert task.kind == "feature"

    result =
      Repo.query!("""
      SELECT column_default, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'tasks' AND column_name = 'kind'
      """)

    assert [[default, "NO"]] = result.rows
    assert default =~ "feature"
  end

  test "the chore predicate uses the composite kind/status index" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan =
      Repo.query!("EXPLAIN SELECT id FROM tasks WHERE kind = 'chore'")
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ "tasks_kind_status_index"
  end

  test "tool definitions enumerate kind on create and update" do
    tools = ToolSurface.tool_definitions()

    for name <- ["task_create", "task_update"] do
      tool = Enum.find(tools, &(&1.name == name))
      assert tool.parameters.kind.type == "string"
      assert tool.parameters.kind.required == false

      for kind <- Task.kinds() do
        assert tool.parameters.kind.description =~ kind
      end
    end
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Task kinds #{System.unique_integer([:positive])}",
        status: "active"
      })

    project
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
