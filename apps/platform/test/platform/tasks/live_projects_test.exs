defmodule Platform.Tasks.LiveProjectsTest do
  @moduledoc """
  Task 01a15ee1 stage 3: the "live project" reads moved out of
  `Platform.Memory.Insights.ProjectInference` into the Tasks context. A
  live project is one in the org that is neither archived nor scheduled
  for deletion.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project

  defp n, do: System.unique_integer([:positive])

  defp project!(org_id) do
    {:ok, project} = Tasks.create_project(%{name: "live-#{n()}", org_id: org_id})
    project
  end

  defp stamp!(project, field),
    do: project |> Project.changeset(%{field => DateTime.utc_now()}) |> Repo.update!()

  test "project_id_for_task/1 reads the task's project; nil for junk or a missing task" do
    org = tenant_org_id("live_#{n()}")
    project = project!(org)
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "t #{n()}"})

    assert Tasks.project_id_for_task(task.id) == project.id
    assert Tasks.project_id_for_task(Ecto.UUID.generate()) == nil
    assert Tasks.project_id_for_task("not-a-uuid") == nil
    assert Tasks.project_id_for_task(nil) == nil
  end

  test "live_project_ids/2 lists only live projects of the org, and honours :limit" do
    org = tenant_org_id("live_#{n()}")
    other = tenant_org_id("live_other_#{n()}")
    a = project!(org)
    b = project!(org)
    archived = stamp!(project!(org), :archived_at)
    doomed = stamp!(project!(org), :deletion_scheduled_at)
    foreign = project!(other)

    ids = Tasks.live_project_ids(org)
    assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    refute archived.id in ids
    refute doomed.id in ids
    refute foreign.id in ids

    assert length(Tasks.live_project_ids(org, limit: 1)) == 1
    assert Tasks.live_project_ids("not-a-uuid") == []
    assert Tasks.live_project_ids(nil) == []
  end

  test "live_project_in_org?/2 is true only for a live project of that org" do
    org = tenant_org_id("live_#{n()}")
    other = tenant_org_id("live_other_#{n()}")
    live = project!(org)
    archived = stamp!(project!(org), :archived_at)
    doomed = stamp!(project!(org), :deletion_scheduled_at)

    assert Tasks.live_project_in_org?(live.id, org)
    assert Tasks.live_project_in_org?(String.upcase(live.id), org)
    refute Tasks.live_project_in_org?(live.id, other)
    refute Tasks.live_project_in_org?(archived.id, org)
    refute Tasks.live_project_in_org?(doomed.id, org)
    refute Tasks.live_project_in_org?(Ecto.UUID.generate(), org)
    refute Tasks.live_project_in_org?("junk", org)
    refute Tasks.live_project_in_org?(nil, org)
  end

  test "live_project_id_by_slug/2 matches a live project's slug case-insensitively" do
    org = tenant_org_id("live_#{n()}")
    other = tenant_org_id("live_other_#{n()}")
    live = project!(org)
    archived = stamp!(project!(org), :archived_at)

    assert Tasks.live_project_id_by_slug("  " <> String.upcase(live.slug) <> " ", org) == live.id
    assert Tasks.live_project_id_by_slug(live.slug, other) == nil
    assert Tasks.live_project_id_by_slug(archived.slug, org) == nil
    assert Tasks.live_project_id_by_slug("", org) == nil
    assert Tasks.live_project_id_by_slug(nil, org) == nil
  end
end
