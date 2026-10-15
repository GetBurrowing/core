defmodule Platform.Access.RolesMigrationTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 1: the migration that creates `access_roles` and
  maps every `org_memberships` row onto a built-in role through the generated
  `access_role_key` column.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.up/4` and `down/4` (mirroring
  `test/platform/branding/burrow_defaults_migration_test.exs`), not a copy of
  its SQL. It is already applied in the test DB, so the first step is a
  `down`. Every step happens inside the SQL sandbox transaction and rolls
  back with the test.

  ## What the mutations detonate

    * Map external to member (edit the CASE): the external rows read
      `member`/`admin` after `up`, and the mapping assertion goes red.
    * Turn the generated column into a plain backfilled column: the
      membership inserted after `up` reads `nil`, and the no-drift test goes
      red.
    * Let `down` touch an original column: the snapshot comparison goes red.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @migration_version 20_261_014_133_107
  @migration_module Platform.Repo.Migrations.CreateAccessRolesAndMapMemberships

  setup_all do
    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@migration_version}_*.exs")
      )

    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)

    :ok
  end

  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  # `access_grants` (task 01a1386d-e528 stage 2, a LATER migration) has an FK
  # to `access_roles(key)`, so this migration's `down` cannot run while it is
  # applied, exactly as in a real rollback, which reverts later migrations
  # first. Roll it back first, inside the same sandbox transaction.
  @grants_version 20_261_014_172_224
  @grants_module Platform.Repo.Migrations.CreateAccessGrants

  # `access_role_assignments` (task 01a1386e-59d1 stage 1, a LATER migration
  # still) has an FK to `access_roles(key)` too, and adds `access_roles.org_id`.
  # It is the latest of the three, so it rolls back first.
  @custom_roles_version 20_261_014_173_546
  @custom_roles_module Platform.Repo.Migrations.AddCustomRolesAndRoleAssignments

  # Channel restrictions also reference access_roles(key), so revert them
  # before exercising the earlier migration's down path.
  @restrictions_version 20_261_014_173_547
  @restrictions_module Platform.Repo.Migrations.CreateAccessSpaceRestrictions

  @idp_group_roles_version 20_261_014_173_548
  @idp_group_roles_module Platform.Repo.Migrations.CreateAccessIdpGroupRoles

  defp up! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
    :ok = Ecto.Migrator.up(Repo, @migration_version, @migration_module, @opts)
  end

  defp down! do
    :ok = Ecto.Migrator.down(Repo, @migration_version, @migration_module, @opts)
  end

  # Every ORIGINAL column of every row, so "no original column changes" is
  # checked, not assumed.
  defp snapshot! do
    %{rows: rows} =
      Repo.query!("""
      SELECT id, user_id, org_id, role, external, roles_locked_at, inserted_at, updated_at
      FROM org_memberships ORDER BY id
      """)

    rows
  end

  defp role_keys!(ids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, access_role_key FROM org_memberships WHERE id = ANY($1)",
        [Enum.map(ids, &Ecto.UUID.dump!/1)]
      )

    Map.new(rows, fn [id, key] -> {Ecto.UUID.load!(id), key} end)
  end

  defp column_present? do
    %{rows: rows} =
      Repo.query!("""
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'org_memberships' AND column_name = 'access_role_key'
      """)

    rows != []
  end

  defp table_present? do
    %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('access_roles')::text")
    regclass != nil
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "roles-migration-#{n}@example.com",
      name: "Roles Migration #{n}",
      oidc_sub: "roles-migration-#{n}"
    })
  end

  defp membership!(org_id, role, external) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user!().id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()
  end

  setup do
    org_id = tenant_org_id("rbac_roles_migration")

    seeded = %{
      admin: membership!(org_id, "admin", false),
      member: membership!(org_id, "member", false),
      external_member: membership!(org_id, "member", true),
      external_admin: membership!(org_id, "admin", true)
    }

    %{org_id: org_id, seeded: seeded}
  end

  # Drop later access migrations AFTER the fixtures above: `tenant_org_id/1`
  # creates its org through `Tenancy.create_org/2`, whose root-admin re-check
  # is `Platform.Access.authorize_install/1` (task 01a1386d-fb6e stage 2) and
  # builds a Scope, which reads `access_grants`.
  setup do
    [idp_group_roles_path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@idp_group_roles_version}_*.exs")
      )

    unless Code.ensure_loaded?(@idp_group_roles_module),
      do: Code.require_file(idp_group_roles_path)

    :ok = Ecto.Migrator.down(Repo, @idp_group_roles_version, @idp_group_roles_module, @opts)

    [restrictions_path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@restrictions_version}_*.exs")
      )

    unless Code.ensure_loaded?(@restrictions_module), do: Code.require_file(restrictions_path)
    :ok = Ecto.Migrator.down(Repo, @restrictions_version, @restrictions_module, @opts)

    [custom_roles_path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@custom_roles_version}_*.exs")
      )

    unless Code.ensure_loaded?(@custom_roles_module), do: Code.require_file(custom_roles_path)
    :ok = Ecto.Migrator.down(Repo, @custom_roles_version, @custom_roles_module, @opts)

    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@grants_version}_*.exs")
      )

    unless Code.ensure_loaded?(@grants_module), do: Code.require_file(path)
    :ok = Ecto.Migrator.down(Repo, @grants_version, @grants_module, @opts)
    :ok
  end

  defp assert_mapped(seeded) do
    keys = role_keys!(Enum.map(seeded, fn {_, m} -> m.id end))

    assert keys[seeded.admin.id] == "admin"
    assert keys[seeded.member.id] == "member"
    assert keys[seeded.external_member.id] == "guest"
    assert keys[seeded.external_admin.id] == "guest"

    # And every OTHER row in the table maps by the same rule, none NULL.
    %{rows: [[mismatches]]} =
      Repo.query!("""
      SELECT count(*) FROM org_memberships
      WHERE access_role_key IS DISTINCT FROM (CASE WHEN external THEN 'guest' ELSE role END)
      """)

    assert mismatches == 0
  end

  test "down, up, down, up: original columns never change; up maps, down removes", %{
    seeded: seeded
  } do
    # Applied by `mix test`'s migrate before the test runs.
    assert column_present?() and table_present?()
    assert_mapped(seeded)
    before = snapshot!()
    assert length(before) >= 4

    down!()
    assert snapshot!() == before
    refute column_present?()
    refute table_present?()

    up!()
    assert snapshot!() == before
    assert column_present?() and table_present?()
    assert_mapped(seeded)

    down!()
    assert snapshot!() == before
    refute column_present?()
    refute table_present?()

    up!()
    assert snapshot!() == before
    assert_mapped(seeded)

    %{rows: keys} = Repo.query!("SELECT key FROM access_roles WHERE builtin ORDER BY key")
    assert keys == [["admin"], ["guest"], ["member"]]
  end

  test "a membership written after up reads its role with no write to access_role_key", %{
    org_id: org_id
  } do
    down!()
    up!()

    # Insert path of mark_membership_external/1.
    new_user = user!()
    {:ok, inserted} = Tenancy.mark_membership_external(%{user_id: new_user.id, org_id: org_id})
    assert inserted.access_role_key == "guest"
    assert Repo.get!(OrgMembership, inserted.id).access_role_key == "guest"

    # Update path: an internal row flipped external re-derives on the same write.
    internal = membership!(org_id, "admin", false)
    assert internal.access_role_key == "admin"

    {:ok, flipped} =
      Tenancy.mark_membership_external(%{user_id: internal.user_id, org_id: org_id})

    assert flipped.access_role_key == "guest"
    assert Repo.get!(OrgMembership, internal.id).access_role_key == "guest"
  end

  test "the column cannot be written, by changeset or by SQL", %{seeded: seeded} do
    # Not castable: the changeset drops it.
    changeset = OrgMembership.changeset(seeded.member, %{access_role_key: "admin"})
    refute Map.has_key?(changeset.changes, :access_role_key)

    # Postgres refuses a direct write to a generated column.
    assert_raise Postgrex.Error, ~r/generated/i, fn ->
      Repo.query!(
        "UPDATE org_memberships SET access_role_key = 'admin' WHERE id = $1",
        [Ecto.UUID.dump!(seeded.member.id)]
      )
    end
  end
end
