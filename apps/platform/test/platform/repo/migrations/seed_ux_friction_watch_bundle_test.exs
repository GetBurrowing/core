defmodule Platform.Repo.Migrations.SeedUxFrictionWatchBundleTest do
  @moduledoc """
  Coverage for `20261107140100_seed_ux_friction_watch_bundle` (task 01a1af00
  stage 1): `up/0` adds the one designer bundle row; `down/0` removes exactly
  that row and nothing else.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.{RoleResponsibility, Seeds}

  @moduletag :regression

  @keys ["ux.friction_watch"]
  @migration_module Platform.Repo.Migrations.SeedUxFrictionWatchBundle

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261107140100_seed_ux_friction_watch_bundle.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = Seeds.seed_defaults()
    :ok
  end

  defp rows do
    Repo.all(
      from(r in RoleResponsibility,
        where: r.role_key == "designer" and r.responsibility_key in ^@keys,
        select: r.responsibility_key
      )
    )
  end

  defp designer_size,
    do: Repo.aggregate(from(r in RoleResponsibility, where: r.role_key == "designer"), :count)

  test "the key is declared by the migration and the designer's seed bundle" do
    assert @migration_module.bundle_keys() == @keys
    designer = Enum.find(Seeds.default_roles(), &(&1.key == "designer"))
    assert "ux.friction_watch" in designer.bundle
  end

  test "up/0 adds the row on a database that lacks it, idempotently" do
    Repo.delete_all(
      from(r in RoleResponsibility,
        where: r.role_key == "designer" and r.responsibility_key in ^@keys
      )
    )

    assert rows() == []
    before = designer_size()

    assert :ok = @migration_module.up()
    assert rows() == @keys
    assert designer_size() == before + 1

    assert :ok = @migration_module.up()
    assert designer_size() == before + 1
    assert "ux.friction_watch" in Roles.bundle_for("designer")
  end

  test "down/0 removes only the friction watch row" do
    before = designer_size()
    assert :ok = @migration_module.down()
    assert rows() == []
    assert designer_size() == before - 1
  end
end
