defmodule Platform.Repo.Migrations.SeedAgentsTeamCheckTemplateAndBundleTest do
  @moduledoc """
  Coverage for `20261107193000_seed_agents_team_check_template_and_bundle`
  (task 01a1b6de stage 3): `up/0` seeds the `agents.team_check.v1` row and
  the one agents_leader bundle row; `down/0` removes exactly those and
  nothing else.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles.{RoleResponsibility, Seeds}

  @moduletag :regression

  @slug "agents.team_check.v1"
  @keys ["agents.team_check"]

  @migration_module Platform.Repo.Migrations.SeedAgentsTeamCheckTemplateAndBundle

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261107193000_seed_agents_team_check_template_and_bundle.exs"
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
      where: r.role_key == "agents_leader" and r.responsibility_key in ^@keys,
      select: r.responsibility_key,
      order_by: r.responsibility_key
    )
    |> Repo.all()
  end

  defp leader_bundle_size do
    Repo.aggregate(from(r in RoleResponsibility, where: r.role_key == "agents_leader"), :count)
  end

  defp remove_everything! do
    Repo.delete_all(from(t in Platform.Orchestration.PromptTemplate, where: t.slug == @slug))

    Repo.delete_all(
      from(r in RoleResponsibility,
        where: r.role_key == "agents_leader" and r.responsibility_key in ^@keys
      )
    )
  end

  test "the migration declares exactly this slug and these bundle keys" do
    assert @migration_module.slugs() == [@slug]
    assert @migration_module.bundle_keys() == @keys
  end

  test "up/0 seeds the template row and the bundle row on a database that lacks them" do
    remove_everything!()
    assert PromptTemplates.get_template_by_slug(@slug) == nil
    assert bundle_rows() == []
    size_before = leader_bundle_size()

    assert :ok = @migration_module.up()

    row = PromptTemplates.get_template_by_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
    assert row.content == descriptor.content
    assert row.variables == descriptor.variables
    assert row.description == descriptor.description
    assert bundle_rows() == @keys
    assert leader_bundle_size() == size_before + 1
  end

  test "up/0 force-updates a stale template row and is idempotent" do
    assert :ok = @migration_module.up()
    row = PromptTemplates.get_template_by_slug(@slug)
    {:ok, _} = PromptTemplates.update_template(row, %{content: "STALE", variables: ["x"]})
    assert PromptTemplates.get_template_by_slug(@slug).content == "STALE"

    assert :ok = @migration_module.up()
    reloaded = PromptTemplates.get_template_by_slug(@slug)
    refute reloaded.content == "STALE"
    assert "raise_list" in reloaded.variables

    assert :ok = @migration_module.up()
    assert PromptTemplates.get_template_by_slug(@slug).content == reloaded.content
    assert bundle_rows() == @keys
  end

  test "down/0 removes the template row and the bundle row and nothing else" do
    assert :ok = @migration_module.up()
    assert bundle_rows() == @keys
    size_with = leader_bundle_size()
    heartbeat_row = PromptTemplates.get_template_by_slug("agents.goal_heartbeat.v1")

    assert :ok = @migration_module.down()

    assert PromptTemplates.get_template_by_slug(@slug) == nil
    assert bundle_rows() == []
    assert leader_bundle_size() == size_with - 1

    # The rest of the agents_leader bundle and the heartbeat template are untouched.
    remaining =
      from(r in RoleResponsibility,
        where: r.role_key == "agents_leader",
        select: r.responsibility_key
      )
      |> Repo.all()
      |> Enum.sort()

    assert "agents.goal_heartbeat" in remaining

    assert heartbeat_row == nil or
             PromptTemplates.get_template_by_slug("agents.goal_heartbeat.v1").content ==
               heartbeat_row.content

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
