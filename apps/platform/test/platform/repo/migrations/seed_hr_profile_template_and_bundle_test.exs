defmodule Platform.Repo.Migrations.SeedHrProfileTemplateAndBundleTest do
  @moduledoc """
  Coverage for `20261105070000_seed_hr_profile_template_and_bundle` (task
  01a1aa47 stage 4): `up/0` seeds the `hr.profile.v1` row and the two
  historian bundle rows; `down/0` removes exactly those and nothing else.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles.{RoleResponsibility, Seeds}

  @moduletag :regression

  @slug "hr.profile.v1"
  @keys ["hr.daily_sweep", "hr.meeting_completed"]

  @migration_module Platform.Repo.Migrations.SeedHrProfileTemplateAndBundle

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261105070000_seed_hr_profile_template_and_bundle.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = Seeds.seed_defaults()
    :ok
  end

  defp bundle_rows do
    from(r in RoleResponsibility,
      where: r.role_key == "historian" and r.responsibility_key in ^@keys,
      select: r.responsibility_key,
      order_by: r.responsibility_key
    )
    |> Repo.all()
  end

  defp historian_bundle_size do
    Repo.aggregate(from(r in RoleResponsibility, where: r.role_key == "historian"), :count)
  end

  defp remove_everything! do
    Repo.delete_all(from(t in Platform.Orchestration.PromptTemplate, where: t.slug == @slug))

    Repo.delete_all(
      from(r in RoleResponsibility,
        where: r.role_key == "historian" and r.responsibility_key in ^@keys
      )
    )
  end

  test "the migration declares exactly this slug and these bundle keys" do
    assert @migration_module.slugs() == [@slug]
    assert @migration_module.bundle_keys() == @keys
  end

  test "up/0 seeds the template row and the two bundle rows on a database that lacks them" do
    remove_everything!()
    assert PromptTemplates.get_template_by_slug(@slug) == nil
    assert bundle_rows() == []
    size_before = historian_bundle_size()

    assert :ok = @migration_module.up()

    row = PromptTemplates.get_template_by_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
    assert row.content == descriptor.content
    assert row.variables == descriptor.variables
    assert row.description == descriptor.description
    assert bundle_rows() == @keys
    assert historian_bundle_size() == size_before + 2
  end

  test "up/0 force-updates a stale template row and is idempotent" do
    assert :ok = @migration_module.up()
    row = PromptTemplates.get_template_by_slug(@slug)
    {:ok, _} = PromptTemplates.update_template(row, %{content: "STALE", variables: ["x"]})
    assert PromptTemplates.get_template_by_slug(@slug).content == "STALE"

    assert :ok = @migration_module.up()
    reloaded = PromptTemplates.get_template_by_slug(@slug)
    refute reloaded.content == "STALE"
    assert "people_own_words" in reloaded.variables

    assert :ok = @migration_module.up()
    assert PromptTemplates.get_template_by_slug(@slug).content == reloaded.content
    assert bundle_rows() == @keys
  end

  test "down/0 removes the template row and the two bundle rows and nothing else" do
    assert :ok = @migration_module.up()
    assert bundle_rows() == @keys
    size_with = historian_bundle_size()
    dreaming_row = PromptTemplates.get_template_by_slug("memory.dreaming.v1")

    assert :ok = @migration_module.down()

    assert PromptTemplates.get_template_by_slug(@slug) == nil
    assert bundle_rows() == []
    assert historian_bundle_size() == size_with - 2

    # The rest of the historian bundle and the dreaming template are untouched.
    remaining =
      from(r in RoleResponsibility,
        where: r.role_key == "historian",
        select: r.responsibility_key
      )
      |> Repo.all()
      |> Enum.sort()

    assert "memory.dreaming" in remaining
    assert "meetings.decision_recorded" in remaining

    assert PromptTemplates.get_template_by_slug("memory.dreaming.v1").content ==
             dreaming_row.content

    assert Repo.aggregate(Platform.Roles.Role, :count, :key) == 10
  end

  test "seed_defaults/0 alone does not repair a stale row — the migration is load-bearing" do
    assert :ok = @migration_module.up()
    row = PromptTemplates.get_template_by_slug(@slug)
    {:ok, _} = PromptTemplates.update_template(row, %{content: "STALE"})

    :ok = PromptTemplates.seed_defaults()
    assert PromptTemplates.get_template_by_slug(@slug).content == "STALE"

    assert :ok = @migration_module.up()
    refute PromptTemplates.get_template_by_slug(@slug).content == "STALE"
  end
end
