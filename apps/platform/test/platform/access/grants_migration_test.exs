defmodule Platform.Access.GrantsMigrationTest do
  @moduledoc """
  Task 01a1386d-e528 stage 2: the migration that adds `access_grants`.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.down/4` and `up/4`, mirroring
  `test/platform/org/wiki/memory_nodes_migration_test.exs`. Every step runs
  inside the SQL sandbox transaction and rolls back with the test.

  Claims: down/up/up leaves the tables it sits beside (`access_roles`,
  `org_memberships`, `org_memory_nodes`) byte-identical, and the rebuilt
  table enforces its principal CHECK and its one-effect-per-tuple index,
  including for role principals whose `principal_id` is NULL.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Grant
  alias Platform.Org.Wiki.Nodes
  alias Platform.Repo

  @migration_version 20_261_014_172_224
  @migration_module Platform.Repo.Migrations.CreateAccessGrants

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

  defp down! do
    :ok = Ecto.Migrator.down(Repo, @migration_version, @migration_module, @opts)
  end

  defp md5(table) do
    %{rows: [[digest]]} =
      Repo.query!(
        "SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t.id), '')) FROM #{table} t",
        []
      )

    digest
  end

  defp snapshot, do: Enum.map(~w(access_roles org_memberships org_memory_nodes), &md5/1)

  defp table?(name) do
    %{rows: [[present?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    present?
  end

  defp role_grant(org_id, effect) do
    %Grant{
      org_id: org_id,
      principal_type: "role",
      principal_role_key: "guest",
      permission: "tasks.read",
      resource_type: "project",
      resource_id: "00000000-0000-7000-8000-000000000001",
      effect: effect
    }
  end

  test "the migration sorts directly after stage 1's org_memory_nodes migration" do
    names =
      Path.join(:code.priv_dir(:platform), "repo/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    i = Enum.find_index(names, &String.starts_with?(&1, "20261014172223_"))
    assert Enum.at(names, i + 1) == "20261014172224_create_access_grants.exs"
  end

  test "down then up leaves its neighbours unchanged and rebuilds the constraints" do
    org = acme_org_id()
    {:ok, _} = Nodes.ensure("org/page/eng/")
    Repo.insert!(role_grant(org, "allow"))
    before = snapshot()

    down!()
    refute table?("access_grants")
    assert snapshot() == before

    up!()
    assert table?("access_grants")
    assert snapshot() == before
    assert Repo.aggregate(Grant, :count) == 0

    Repo.insert!(role_grant(org, "allow"))

    # A NULL principal_id does not make two role rows distinct.
    assert_raise Ecto.ConstraintError, ~r/access_grants_tuple_index/, fn ->
      Repo.insert!(role_grant(org, "deny"))
    end
  end

  test "the principal CHECK refuses a role row carrying a principal_id" do
    org = acme_org_id()

    assert_raise Ecto.ConstraintError, ~r/access_grants_principal_check/, fn ->
      Repo.insert!(%{role_grant(org, "allow") | principal_id: Ecto.UUID.generate()})
    end
  end
end
