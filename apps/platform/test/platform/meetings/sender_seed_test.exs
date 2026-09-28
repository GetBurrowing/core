defmodule Platform.Meetings.SenderSeedTest do
  # NOT async. Two reasons, both real:
  #   1. The `Config.enabled?/0` tests mutate `Application.put_env`, which
  #      is global — an async sibling reading the flag would see it flip.
  #   2. `SenderSeed.ensure!/0` takes a constant-key advisory lock. Two
  #      async tests on different sandbox connections would serialize on
  #      it for the whole length of their sandbox transactions.
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.Config
  alias Platform.Meetings.SenderSeed

  defp seeded_count do
    Repo.aggregate(from(a in Agent, where: a.slug == ^SenderSeed.slug()), :count)
  end

  describe "ensure!/0" do
    test "seeds the meetings sender agent with the expected shape" do
      assert {:ok, %Agent{} = agent} = SenderSeed.ensure!()

      assert agent.slug == "meetings"
      assert agent.name == "Meetings"
      assert agent.status == "active"
      assert agent.kind == "native"
      assert agent.runtime_type == "built_in"
      assert is_nil(agent.workspace_id)
    end

    test "is idempotent: two calls leave exactly one row and return the same id" do
      # The count assertion is the load-bearing one. Asserting `{:ok, _}`
      # twice passes just as happily against a seeder that inserts a second
      # row every boot — and before migration 20260928230000 it would have,
      # because `agents_unique_slug` was a plain UNIQUE index over
      # (workspace_id, slug) with `indnullsnotdistinct = false`, which
      # constrained nothing when workspace_id IS NULL (measured on Postgres
      # 16.12: two `ON CONFLICT (workspace_id, slug) DO NOTHING` inserts
      # produced two rows). The index is NULLS NOT DISTINCT now (task
      # 01a0e77c), but idempotency still comes from the advisory lock; see
      # the SenderSeed moduledoc.
      assert seeded_count() == 0

      assert {:ok, first} = SenderSeed.ensure!()
      assert {:ok, second} = SenderSeed.ensure!()

      assert seeded_count() == 1
      assert first.id == second.id
    end

    test "a third call still leaves one row" do
      {:ok, first} = SenderSeed.ensure!()
      {:ok, _} = SenderSeed.ensure!()
      {:ok, third} = SenderSeed.ensure!()

      assert seeded_count() == 1
      assert third.id == first.id
    end

    test "does not adopt a same-slug agent that belongs to a workspace" do
      # A workspace-scoped agent that happens to use the slug is a
      # different row entirely; the seeder must not return it, and must
      # still insert its own workspace-less row.
      workspace_id = Ecto.UUID.generate()

      {:ok, scoped} =
        %Agent{}
        |> Agent.changeset(%{
          slug: SenderSeed.slug(),
          name: "Someone else's meetings agent",
          status: "active",
          workspace_id: workspace_id
        })
        |> Repo.insert()

      assert {:ok, seeded} = SenderSeed.ensure!()

      refute seeded.id == scoped.id
      assert is_nil(seeded.workspace_id)
      assert Repo.get(Agent, scoped.id).workspace_id == workspace_id
    end
  end

  describe "get/0" do
    test "returns nil before seeding and the agent after" do
      assert is_nil(SenderSeed.get())

      {:ok, agent} = SenderSeed.ensure!()

      assert SenderSeed.get().id == agent.id
    end
  end

  describe "Config.enabled?/0" do
    setup do
      original = Application.fetch_env(:platform, :meetings_enabled)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:platform, :meetings_enabled, value)
          :error -> Application.delete_env(:platform, :meetings_enabled)
        end
      end)

      :ok
    end

    test "is false when the injected key is false" do
      Application.put_env(:platform, :meetings_enabled, false)

      refute Config.enabled?()
    end

    test "is true when the injected key is true" do
      Application.put_env(:platform, :meetings_enabled, true)

      assert Config.enabled?()
    end

    test "the injected key wins over the environment" do
      # This is the property every later stage's flag-off test depends on:
      # if injection did not short-circuit the env read, a developer with
      # MEETINGS_ENABLED exported would get different results from CI.
      Application.put_env(:platform, :meetings_enabled, false)
      refute Config.enabled?()

      Application.put_env(:platform, :meetings_enabled, true)
      assert Config.enabled?()
    end

    test "falls through to the environment variable when the key is absent" do
      # Deliberately does NOT set a real OS env var — the suite must not
      # mutate the host environment. Assert the fall-through by comparing
      # against whatever the host actually has.
      Application.delete_env(:platform, :meetings_enabled)

      assert Config.enabled?() == (System.get_env("MEETINGS_ENABLED") == "true")
    end

    test "config/test.exs pins the flag off so the suite never reads the host env" do
      assert Application.fetch_env(:platform, :meetings_enabled) == {:ok, false}
    end
  end
end
