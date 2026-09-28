defmodule Platform.Repo.Migrations.EnforceAgentSlugUniquenessAcrossNullWorkspaceTest do
  @moduledoc """
  Task 01a0e77c stage 4 — behavioural coverage for the parking pass of
  `20260928230000_enforce_agent_slug_uniqueness_across_null_workspace`.
  Mirrors `EnforceVaultSlugUniquenessAcrossNullScopesTest`.

  The suite migrates an EMPTY database, where the parking pass matches zero
  rows and is indistinguishable from a deleted one. So this file seeds
  duplicates under the restored permissive index (`down/0`), runs the SHIPPED
  `up/0` through `Ecto.Migration.Runner` on the test process's sandboxed
  connection, and reads the rows back. Everything rolls back with the test.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent

  @migration Platform.Repo.Migrations.EnforceAgentSlugUniquenessAcrossNullWorkspace

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/" <>
                      "20260928230000_enforce_agent_slug_uniqueness_across_null_workspace.exs",
                    __DIR__
                  )

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  # See the vault migration test: the public migrator runs in a Task with its
  # own checkout, which the sandbox refuses; driving the runner directly keeps
  # every statement on this process's connection. `:forward` both ways because
  # the migration issues plain `execute/1` strings.
  defp run_migration!(operation) when operation in [:up, :down] do
    {:ok, runner} =
      Ecto.Migration.Runner.start_link(
        {self(), Repo, Repo.config(), @migration, :forward, operation,
         %{level: false, sql: false}}
      )

    Ecto.Migration.Runner.metadata(runner, [])
    apply(@migration, operation, [])
    Ecto.Migration.Runner.flush()
    Ecto.Migration.Runner.stop()
    :ok
  end

  defp nulls_not_distinct? do
    %{rows: [[flag]]} =
      Repo.query!("""
      SELECT ix.indnullsnotdistinct
        FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid
       WHERE i.relname = 'agents_unique_slug'
      """)

    flag
  end

  defp insert_raw!(slug, opts \\ []) do
    now = Keyword.get(opts, :updated_at, DateTime.utc_now())

    Repo.insert!(%Agent{
      slug: slug,
      name: Keyword.get(opts, :name, slug),
      status: Keyword.get(opts, :status, "active"),
      workspace_id: Keyword.get(opts, :workspace_id),
      inserted_at: Keyword.get(opts, :inserted_at, now),
      updated_at: now
    })
  end

  defp reload(%Agent{id: id}), do: Repo.get!(Agent, id)

  defp count_slug(slug),
    do: Repo.one(from(a in Agent, where: a.slug == ^slug, select: count(a.id)))

  describe "the parking pass" do
    setup do
      :ok = run_migration!(:down)

      # CONTROL: if down/0 did not relax the index, every "was parked"
      # assertion below would be measuring a setup that never duplicated.
      refute nulls_not_distinct?(), "expected down/0 to restore the permissive index"
      :ok
    end

    test "an active row beats a more recently updated archived one; the loser is renamed, not deleted" do
      slug = "twin-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      total_before = Repo.aggregate(Agent, :count)

      active = insert_raw!(slug, status: "active", updated_at: t0)
      archived = insert_raw!(slug, status: "archived", updated_at: DateTime.add(t0, 600, :second))

      # The bug, reproduced: two NULL-workspace rows share one slug.
      assert count_slug(slug) == 2

      :ok = run_migration!(:up)

      assert reload(active).slug == slug
      assert reload(archived).slug == "#{slug}__dup_#{archived.id}"
      assert count_slug(slug) == 1
      assert Repo.aggregate(Agent, :count) == total_before + 2, "no row may be deleted"
      assert nulls_not_distinct?()
    end

    test "among equally active rows the most recently updated wins" do
      slug = "twin-upd-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]

      older = insert_raw!(slug, updated_at: t0)
      newer = insert_raw!(slug, updated_at: DateTime.add(t0, 60, :second), inserted_at: t0)
      oldest = insert_raw!(slug, updated_at: DateTime.add(t0, -60, :second))

      :ok = run_migration!(:up)

      assert reload(newer).slug == slug
      assert reload(older).slug == "#{slug}__dup_#{older.id}"
      assert reload(oldest).slug == "#{slug}__dup_#{oldest.id}"
    end

    test "leaves the same slug in distinct workspaces alone" do
      slug = "twin-ws-#{System.unique_integer([:positive])}"
      a = insert_raw!(slug, workspace_id: Ecto.UUID.generate())
      b = insert_raw!(slug, workspace_id: Ecto.UUID.generate())
      c = insert_raw!(slug)

      :ok = run_migration!(:up)

      assert reload(a).slug == slug
      assert reload(b).slug == slug
      assert reload(c).slug == slug
    end

    test "a parked agent keeps its id and its references" do
      slug = "twin-ref-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      _winner = insert_raw!(slug, updated_at: DateTime.add(t0, 60, :second))
      loser = insert_raw!(slug, updated_at: t0)

      {:ok, file} =
        Platform.Agents.MemoryContext.upsert_workspace_file(loser.id, "SOUL.md", "kept")

      :ok = run_migration!(:up)

      assert reload(loser).id == loser.id
      assert Repo.get!(Platform.Agents.WorkspaceFile, file.id).agent_id == loser.id
    end

    test "up/0 on a table with no duplicates parks nothing and installs the strict index" do
      slug = "clean-#{System.unique_integer([:positive])}"
      only = insert_raw!(slug)

      :ok = run_migration!(:up)

      assert reload(only).slug == slug
      assert nulls_not_distinct?()
    end
  end
end
