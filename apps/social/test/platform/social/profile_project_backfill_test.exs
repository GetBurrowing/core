defmodule Platform.Social.ProfileProjectBackfillTest do
  @moduledoc """
  Task 01a16532 stage 2: the backfill migration's data step gives a
  project-less profile the same project `Social.default_render_project_id/1`
  would, is idempotent, never overwrites a set project, and leaves a
  profile in a project-less org NULL.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  require Ecto.Query

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.Profile

  @migration Platform.Repo.Migrations.BackfillSocialProfileProject

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Platform.Social.Extension.migrations_path()
      |> Path.join("20261023070500_backfill_social_profile_project.exs")
      |> Code.require_file()
    end

    :ok
  end

  # `apply/3`: the migration is an .exs loaded at runtime, so a remote call
  # would warn at compile time that the module is not available.
  defp backfill!, do: Repo.query!(apply(@migration, :backfill_sql, [])).num_rows

  defp project!(org_id, name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: name, org_id: org_id, slug: "p-#{unique()}"})

    project
  end

  defp archive!(project) do
    {:ok, project} = Platform.Tasks.update_project(project, %{archived_at: DateTime.utc_now()})
    project
  end

  # A legacy profile: created with no project, as before stage 1.
  defp bare_profile!(org_id) do
    {:ok, profile} = Social.create_profile(org_id, %{name: "Legacy #{unique()}", project_id: nil})
    profile
  end

  defp reload(profile), do: Repo.get!(Profile, profile.id)

  setup do
    none = org_id!()

    one = org_id!()
    only = project!(one, "Only")

    many = org_id!()
    project!(many, "Aardvark") |> archive!()
    project!(many, "Zulu")
    first = project!(many, "Mike")
    # Lowercase sorts after uppercase in byte order (and before it under
    # en_US): the case that tells the two collations apart.
    project!(many, "alpha")

    set_org = org_id!()
    project!(set_org, "Alpha")
    chosen = project!(set_org, "Zulu")

    {:ok, already} =
      Social.create_profile(set_org, %{name: "Chosen #{unique()}", project_id: chosen.id})

    %{
      none: {none, bare_profile!(none)},
      one: {one, bare_profile!(one), only},
      many: {many, bare_profile!(many), first},
      already: {already, chosen}
    }
  end

  test "the backfill agrees with the resolver for 0, 1 and 2+ project orgs", w do
    {none, p0} = w.none
    {one, p1, only} = w.one
    {many, p2, first} = w.many

    assert reload(p0).project_id == nil
    assert reload(p1).project_id == nil
    assert reload(p2).project_id == nil

    assert backfill!() >= 2

    assert reload(p0).project_id == Social.default_render_project_id(none)
    assert reload(p1).project_id == Social.default_render_project_id(one)
    assert reload(p2).project_id == Social.default_render_project_id(many)

    assert reload(p1).project_id == only.id
    assert reload(p2).project_id == first.id
  end

  test "an org with no projects stays NULL and gains no project", w do
    {none, p0} = w.none
    backfill!()
    assert reload(p0).project_id == nil
    assert Platform.Tasks.list_projects_unscoped(org_id: none) == []
  end

  test "a profile that already has a project is never overwritten", w do
    {already, chosen} = w.already
    before = reload(already)
    backfill!()
    after_run = reload(already)
    assert after_run.project_id == chosen.id
    assert after_run.updated_at == before.updated_at
  end

  test "a second run updates nothing and changes no value", w do
    {_, p1, _} = w.one
    {_, p2, _} = w.many
    backfill!()
    first_run = Enum.map([p1, p2], &reload/1)

    assert backfill!() == 0

    assert Enum.map([p1, p2], &reload/1) == first_run
  end
end
