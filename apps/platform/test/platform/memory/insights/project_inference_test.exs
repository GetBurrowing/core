defmodule Platform.Memory.Insights.ProjectInferenceTest do
  @moduledoc """
  Task 01a15ee1 stage 2: `ProjectInference.infer/1` takes the first rung
  that names a live project in the insight's org. Each rung is tested in an
  org of its own with two live projects, so rung 4 ("only project") cannot
  answer in its place; rung 4 has its own org with exactly one. Every
  skip (archived, scheduled for deletion, another org's, missing) is shown
  falling through to the next rung, which proves the skip and not just the
  miss.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Memory.Insights.ProjectInference
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project

  defp n, do: System.unique_integer([:positive])

  defp org!, do: tenant_org_id("infer_#{n()}")

  defp project!(org_id, attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(Map.merge(%{name: "infer-#{n()}", org_id: org_id}, attrs))

    project
  end

  defp archive!(project),
    do: project |> Project.changeset(%{archived_at: DateTime.utc_now()}) |> Repo.update!()

  defp insight(org_id, attrs) do
    Map.merge(
      %{
        org_id: org_id,
        action: %{},
        journal_path: "org/journal/2026-10-21.md",
        source_ref: nil
      },
      Map.new(attrs)
    )
  end

  # An org with two live projects (so "only project" never answers).
  defp two_project_org! do
    org = org!()
    {org, project!(org), project!(org)}
  end

  test "rung 1: project_id, then a uuid target, is named by dreaming" do
    {org, a, b} = two_project_org!()

    assert ProjectInference.infer(insight(org, action: %{"project_id" => a.id})) ==
             {a.id, "named by dreaming"}

    assert ProjectInference.infer(insight(org, action: %{"target" => b.id})) ==
             {b.id, "named by dreaming"}

    # project_id wins over target.
    assert ProjectInference.infer(insight(org, action: %{"project_id" => a.id, "target" => b.id})) ==
             {a.id, "named by dreaming"}

    # An upper-case uuid is the same project.
    assert ProjectInference.infer(insight(org, action: %{"target" => String.upcase(b.id)})) ==
             {b.id, "named by dreaming"}
  end

  test "rung 1: a target matching a project slug case-insensitively is named by slug" do
    {org, a, _b} = two_project_org!()

    assert ProjectInference.infer(insight(org, action: %{"target" => String.upcase(a.slug)})) ==
             {a.id, "named by slug"}
  end

  test "rung 2: a project journal names its project" do
    {org, a, _b} = two_project_org!()

    assert ProjectInference.infer(
             insight(org, journal_path: "project/#{a.id}/journal/2026-10-21.md")
           ) == {a.id, "journal's project"}
  end

  test "rung 3: a cited task names its project" do
    {org, _a, b} = two_project_org!()
    {:ok, task} = Tasks.create_task(%{project_id: b.id, title: "cited #{n()}"})

    assert ProjectInference.infer(insight(org, source_ref: "task:#{task.id}")) ==
             {b.id, "cited task's project"}
  end

  test "rung 4: the org's only live project" do
    org = org!()
    only = project!(org)
    archive!(project!(org))

    assert ProjectInference.infer(insight(org, [])) == {only.id, "only project"}
  end

  test "nil with two live projects and no hints" do
    {org, _a, _b} = two_project_org!()

    assert ProjectInference.infer(insight(org, [])) == nil
    assert ProjectInference.infer(insight(org, action: %{"target" => "no-such-slug"})) == nil
  end

  test "an archived named project is skipped and the next rung answers" do
    {org, a, b} = two_project_org!()
    archive!(a)

    assert ProjectInference.infer(
             insight(org,
               action: %{"project_id" => a.id},
               journal_path: "project/#{b.id}/journal/2026-10-21.md"
             )
           ) == {b.id, "journal's project"}

    # Archived by slug, by journal and by cited task: all skipped.
    {:ok, task} = Tasks.create_task(%{project_id: b.id, title: "cited #{n()}"})
    archive!(b)

    assert ProjectInference.infer(
             insight(org,
               action: %{"target" => a.slug},
               journal_path: "project/#{b.id}/journal/2026-10-21.md",
               source_ref: "task:#{task.id}"
             )
           ) == nil
  end

  test "a project scheduled for deletion is skipped" do
    {org, a, b} = two_project_org!()

    a
    |> Project.changeset(%{deletion_scheduled_at: DateTime.utc_now()})
    |> Repo.update!()

    # Not named; and with `a` gone, `b` is the org's only live project.
    assert ProjectInference.infer(insight(org, action: %{"project_id" => a.id})) ==
             {b.id, "only project"}
  end

  test "another org's project, or a missing one, is skipped" do
    {org, _a, b} = two_project_org!()
    foreign = project!(org!())

    assert ProjectInference.infer(
             insight(org,
               action: %{"project_id" => foreign.id, "target" => Ecto.UUID.generate()},
               source_ref: "task:#{Ecto.UUID.generate()}",
               journal_path: "project/#{b.id}/journal/2026-10-21.md"
             )
           ) == {b.id, "journal's project"}

    assert ProjectInference.infer(insight(org, action: %{"target" => foreign.slug})) == nil
  end
end
