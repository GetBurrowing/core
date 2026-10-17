defmodule Platform.Access.ModuleLockMigrationTest do
  @moduledoc """
  Task 01a14721 stage 2: the migration that admits module-lock rows in
  `access_grants`. The ACTUAL migration file is loaded off the migration
  path and run with `Ecto.Migrator.down/4` and `up/4`, as
  `grants_migration_test.exs` runs its own. Every step runs inside the SQL
  sandbox transaction and rolls back with the test.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access.Grant
  alias Platform.Repo

  @migration_version 20_261_017_000_000
  @migration_module Platform.Repo.Migrations.AccessGrantsModuleLocks

  setup_all do
    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@migration_version}_*.exs")
      )

    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)

    :ok
  end

  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  defp up! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
    :ok = Ecto.Migrator.up(Repo, @migration_version, @migration_module, @opts)
  end

  defp down!, do: :ok = Ecto.Migrator.down(Repo, @migration_version, @migration_module, @opts)

  defp row(org, effect, type \\ "module") do
    %Grant{
      org_id: org,
      principal_type: "role",
      principal_role_key: "member",
      permission: if(type == "module", do: "files", else: "files.read"),
      resource_type: type,
      resource_id: org,
      effect: effect
    }
  end

  defp module_rows,
    do: Repo.one!(from(g in Grant, where: g.resource_type == "module", select: count()))

  test "the stamp sorts after every earlier migration and is unique" do
    names =
      Path.join(:code.priv_dir(:platform), "repo/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert Enum.count(names, &String.starts_with?(&1, "20261017000000_")) == 1
    i = Enum.find_index(names, &(&1 == "20261017000000_access_grants_module_locks.exs"))
    assert Enum.at(names, i - 1) < "20261017000000"
    assert "20261016040000_create_access_change_proposals.exs" in Enum.take(names, i)
  end

  test "up admits a module deny and refuses a module allow" do
    org = acme_org_id()
    Repo.insert!(row(org, "deny"))
    assert module_rows() == 1

    assert_raise Ecto.ConstraintError, ~r/access_grants_module_deny_check/, fn ->
      Repo.insert!(%{row(org, "allow") | principal_role_key: "admin"})
    end
  end

  test "down deletes module rows and restores the original CHECK; up re-admits them" do
    org = acme_org_id()
    Repo.insert!(row(org, "deny"))
    Repo.insert!(row(org, "allow", "project"))

    down!()
    assert module_rows() == 0
    # The non-module row survives.
    assert Repo.aggregate(Grant, :count) >= 1

    assert_raise Ecto.ConstraintError, ~r/access_grants_resource_type_check/, fn ->
      Repo.insert!(row(org, "deny"))
    end
  end

  test "down then up rebuilds both CHECKs" do
    org = acme_org_id()
    down!()
    up!()

    Repo.insert!(row(org, "deny"))
    assert module_rows() == 1

    assert_raise Ecto.ConstraintError, ~r/access_grants_module_deny_check/, fn ->
      Repo.insert!(%{row(org, "allow") | principal_role_key: "admin"})
    end
  end
end
