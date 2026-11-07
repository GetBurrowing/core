defmodule Platform.Roles.BurrowHoldsUnheldRolesMigrationTest do
  @moduledoc """
  Task 01a1b741 stage 1: the one-shot data migration that gives an existing
  install's Burrow every role no agent holds.

  The ACTUAL migration file is loaded off the migration path and run with
  `Ecto.Migrator.up/4` (the pattern of
  `test/platform/access/custom_roles_migration_test.exs`). It is already
  applied in the test DB, so each run first deletes its `schema_migrations`
  row. Everything happens inside the SQL sandbox and rolls back with the test.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.{Agent, Burrow, NativeAgents}
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleAssignment}

  @migration_version 20_261_107_193_100
  @migration_module Platform.Repo.Migrations.BurrowHoldsUnheldRoles

  setup_all do
    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@migration_version}_*.exs")
      )

    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)

    :ok
  end

  setup do
    for key <- Role.valid_keys(), do: :ok = Roles.unassign_role(key)
    :ok
  end

  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  defp up! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])
    :ok = Ecto.Migrator.up(Repo, @migration_version, @migration_module, @opts)
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      email: "burrow-migration-#{n}@example.com",
      name: "Owner #{n}",
      oidc_sub: "oidc-burrow-migration-#{n}"
    })
  end

  # A Burrow from before this change: created, holding no role.
  defp burrow_without_roles! do
    {:ok, agent, _runtime} =
      NativeAgents.create(user!().id, %{name: "Burrow", harness: "claude_code"})

    assert agent.slug == "burrow"
    assert Burrow.get().id == agent.id
    assert Roles.roles_for(agent.id) == []
    agent
  end

  defp other_agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "other-#{n}", name: "Other #{n}", status: "active"})
    |> Repo.insert!()
  end

  defp rows, do: Repo.all(from(ra in RoleAssignment, order_by: ra.role_key))

  test "Burrow takes every unheld role; a held role keeps its holder; a re-run changes nothing" do
    burrow = burrow_without_roles!()
    other = other_agent!()
    {:ok, historian} = Roles.assign_role("historian", other.id)

    up!()

    assert Roles.agent_id_for_role("historian") == other.id
    assert Repo.get!(RoleAssignment, historian.id) == historian

    taken = Role.valid_keys() -- ["historian"]
    assert length(taken) == 9

    for key <- taken, do: assert(Roles.agent_id_for_role(key) == burrow.id, key)

    after_first = rows()
    assert length(after_first) == 10

    up!()
    assert rows() == after_first
  end

  test "with no Burrow agent nothing is inserted" do
    other = other_agent!()
    {:ok, _} = Roles.assign_role("historian", other.id)
    before = rows()

    up!()

    assert rows() == before
  end
end
