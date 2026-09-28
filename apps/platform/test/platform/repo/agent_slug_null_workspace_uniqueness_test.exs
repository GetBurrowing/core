defmodule Platform.Repo.AgentSlugNullWorkspaceUniquenessTest do
  @moduledoc """
  Task 01a0e77c stage 4 — `agents_unique_slug` is `NULLS NOT DISTINCT`.

  Before migration `20260928230000_enforce_agent_slug_uniqueness_across_null_workspace`
  the index was plain `UNIQUE (workspace_id, slug)`, which skips the conflict
  check for any row whose `workspace_id` is NULL — and every production agent
  row is NULL-workspace (22 of 22 on the prod install, measured 2026-09-28).
  These tests read the live index and drive the changeset, so they go red if
  the migration is missing or reverted.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Meetings.SenderSeed
  alias Platform.Repo

  defp insert_agent(attrs) do
    %Agent{}
    |> Agent.changeset(Map.merge(%{name: "Agent", status: "active"}, attrs))
    |> Repo.insert()
  end

  defp unique_slug, do: "nulluniq-#{System.unique_integer([:positive])}"

  test "agents_unique_slug is a unique index with NULLS NOT DISTINCT" do
    %{rows: rows} =
      Repo.query!("""
      SELECT ix.indisunique, ix.indnullsnotdistinct
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
       WHERE i.relname = 'agents_unique_slug'
      """)

    assert rows == [[true, true]]
  end

  test "a second NULL-workspace agent with the same slug is a changeset error, not a raise" do
    slug = unique_slug()

    assert {:ok, _first} = insert_agent(%{slug: slug})
    assert {:error, %Ecto.Changeset{} = changeset} = insert_agent(%{slug: slug})

    assert {"slug already taken in this workspace", opts} = changeset.errors[:slug]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "agents_unique_slug"
  end

  test "the same slug in two distinct workspaces still inserts (uniqueness stays per workspace)" do
    slug = unique_slug()

    assert {:ok, a} = insert_agent(%{slug: slug, workspace_id: Ecto.UUID.generate()})
    assert {:ok, b} = insert_agent(%{slug: slug, workspace_id: Ecto.UUID.generate()})
    assert {:ok, c} = insert_agent(%{slug: slug})

    assert length(Enum.uniq([a.id, b.id, c.id])) == 3
  end

  test "the same slug twice in ONE non-nil workspace is still refused" do
    slug = unique_slug()
    wid = Ecto.UUID.generate()

    assert {:ok, _} = insert_agent(%{slug: slug, workspace_id: wid})

    assert {:error, %Ecto.Changeset{errors: [slug: _]}} =
             insert_agent(%{slug: slug, workspace_id: wid})
  end

  test "SenderSeed.ensure!/0 twice still yields exactly one meetings row" do
    import Ecto.Query

    assert {:ok, first} = SenderSeed.ensure!()
    assert {:ok, second} = SenderSeed.ensure!()
    assert first.id == second.id

    count =
      Repo.aggregate(
        from(a in Agent, where: a.slug == ^SenderSeed.slug() and is_nil(a.workspace_id)),
        :count
      )

    assert count == 1
  end
end
