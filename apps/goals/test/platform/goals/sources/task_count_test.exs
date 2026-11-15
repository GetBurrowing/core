defmodule Platform.Goals.Sources.TaskCountTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.NumberAssertions
  alias Platform.Goals.{Goal, Sources.TaskCount}
  alias Platform.Tasks.{Project, Task}

  setup do
    org = org_id!()
    project = project!(org)
    for status <- ~w(backlog in_progress blocked done done cancelled), do: task!(project, status)
    task!(project, "backlog", DateTime.utc_now())
    other = project!(org)
    for _ <- 1..4, do: task!(other, "backlog")

    %{
      org: org,
      project: project,
      goal: %Goal{org_id: org, source_settings: %{"project_id" => project.id, "count" => "open"}}
    }
  end

  test "one project counts open and completed tasks with stable populations and units", c do
    assert {:ok, %{value: 3, unit: "open tasks", population: population}} =
             TaskCount.measure(c.goal)

    assert population == "task_count:#{c.project.id}:open"
    assert TaskCount.population(c.goal) == {:ok, population}
    refute number_free?(TaskCount.measure(c.goal))
    completed = %{c.goal | source_settings: Map.put(c.goal.source_settings, "count", "completed")}

    assert {:ok, %{value: 2, unit: "tasks done", population: population}} =
             TaskCount.measure(completed)

    assert population == "task_count:#{c.project.id}:completed"
    assert {:ok, %{unit: "issues"}} = TaskCount.measure(%{c.goal | unit: "issues"})
    assert {:ok, %{unit: "open tasks"}} = TaskCount.measure(%{c.goal | unit: "  "})
  end

  test "invalid and foreign project scopes refuse without a number", c do
    foreign = project!(org_id!())
    task!(foreign, "backlog")
    # Current core requires project orgs. Relax only this sandbox transaction to
    # exercise the source's defensive handling of a legacy unscoped row.
    Repo.query!("ALTER TABLE projects ALTER COLUMN org_id DROP NOT NULL")
    unscoped = project!(nil)
    archived = project!(c.org, %{archived_at: DateTime.utc_now()})
    deleting = project!(c.org, %{deletion_scheduled_at: DateTime.utc_now()})

    settings =
      [%{"count" => "open"}] ++
        Enum.map(
          [
            nil,
            "not-a-uuid",
            <<0::128>>,
            Ecto.UUID.generate(),
            foreign.id,
            unscoped.id,
            archived.id,
            deleting.id
          ],
          &%{"count" => "open", "project_id" => &1}
        )

    for settings <- settings do
      goal = %{c.goal | source_settings: settings}

      for result <- [TaskCount.population(goal), TaskCount.measure(goal)] do
        assert result == {:cannot_measure, :unknown_project}
        assert number_free?(result)
      end
    end

    missing_org = %{c.goal | org_id: Ecto.UUID.generate()}
    assert TaskCount.measure(missing_org) == {:cannot_measure, :unknown_project}

    assert {:ok, %{value: 3}} =
             TaskCount.measure(%{c.goal | org_id: Platform.TenancyFixtures.acme_org_id()})
  end

  test "count settings have no default and atom keys are not database settings", c do
    for settings <- [
          %{"project_id" => c.project.id},
          %{"project_id" => c.project.id, "count" => "all"},
          %{project_id: c.project.id, count: "open"},
          nil
        ] do
      goal = %{c.goal | source_settings: settings}

      for result <- [TaskCount.population(goal), TaskCount.measure(goal)] do
        assert result == {:cannot_measure, :bad_settings}
        assert number_free?(result)
      end
    end
  end

  defp project!(org, attrs \\ %{}) do
    Repo.insert!(
      struct(Project, Map.merge(%{org_id: org, name: "Count", slug: "count-#{unique()}"}, attrs))
    )
  end

  defp task!(project, status, deleted_at \\ nil) do
    Repo.insert!(%Task{
      project_id: project.id,
      title: "Count",
      status: status,
      deleted_at: deleted_at
    })
  end
end
