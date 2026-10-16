defmodule Platform.Access.CustomRolesMigrationTest do
  @moduledoc """
  Task 01a1386e-59d1 stage 1: the migration that adds `access_roles.org_id`
  and creates `access_role_assignments`.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.up/4` and `down/4` (mirroring
  `test/platform/branding/burrow_defaults_migration_test.exs`), not a copy of
  its SQL. It is already applied in the test DB, so the first step is a
  `down`. Every step happens inside the SQL sandbox transaction and rolls
  back with the test.

  An md5 of the built-in `access_roles` rows (their original columns) and of
  every `org_memberships` row (every column, including member 2's generated
  `access_role_key`) is taken before and compared after each step, so "no
  existing row changes meaning" is measured, not assumed.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @migration_version 20_261_014_173_546
  @migration_module Platform.Repo.Migrations.AddCustomRolesAndRoleAssignments

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

  defp md5!(sql) do
    %{rows: [[md5]]} =
      Repo.query!(
        "SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) FROM (#{sql}) t"
      )

    md5
  end

  defp snapshot! do
    {
      md5!(
        "SELECT id, key, name, builtin, permissions, inserted_at, updated_at " <>
          "FROM access_roles WHERE builtin"
      ),
      md5!("SELECT * FROM org_memberships")
    }
  end

  defp column_present? do
    %{rows: rows} =
      Repo.query!("""
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'access_roles' AND column_name = 'org_id'
      """)

    rows != []
  end

  defp table_present? do
    %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('access_role_assignments')::text")
    regclass != nil
  end

  defp generated? do
    %{rows: [[generated]]} =
      Repo.query!("""
      SELECT is_generated FROM information_schema.columns
      WHERE table_name = 'org_memberships' AND column_name = 'access_role_key'
      """)

    generated == "ALWAYS"
  end

  setup do
    org_id = tenant_org_id("custom_roles_migration")

    for {role, external} <- [{"admin", false}, {"member", false}, {"member", true}] do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{
          email: "cr-migration-#{n}@example.com",
          name: "CR Migration #{n}",
          oidc_sub: "cr-migration-#{n}"
        })

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: org_id,
        role: role,
        external: external
      })
      |> Repo.insert!()
    end

    %{org_id: org_id}
  end

  test "down, up, down, up: built-in roles and memberships never change", %{org_id: org_id} do
    assert column_present?() and table_present?()
    before = snapshot!()

    # A custom role and an assignment exist before the first down.
    Repo.query!(
      "INSERT INTO access_roles (key, name, builtin, permissions, org_id, inserted_at, updated_at) " <>
        "VALUES ('custom:mig', 'Mig', false, '{}', $1, now(), now())",
      [Ecto.UUID.dump!(org_id)]
    )

    down!()
    assert snapshot!() == before
    refute column_present?()
    refute table_present?()
    assert generated?()

    %{rows: [[custom]]} = Repo.query!("SELECT count(*) FROM access_roles WHERE NOT builtin")
    assert custom == 0

    up!()
    assert snapshot!() == before
    assert column_present?() and table_present?()
    assert generated?()

    down!()
    assert snapshot!() == before

    up!()
    assert snapshot!() == before
    assert generated?()

    %{rows: [[nulls]]} =
      Repo.query!("SELECT count(*) FROM access_roles WHERE builtin AND org_id IS NOT NULL")

    assert nulls == 0

    # The CHECK refuses an org-less custom role after up.
    assert_raise Postgrex.Error, ~r/access_roles_custom_org_check/, fn ->
      Repo.query!(
        "INSERT INTO access_roles (key, name, builtin, permissions, inserted_at, updated_at) " <>
          "VALUES ('custom:orphan', 'Orphan', false, '{}', now(), now())"
      )
    end
  end
end
