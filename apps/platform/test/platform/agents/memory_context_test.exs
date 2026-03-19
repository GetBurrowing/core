defmodule Platform.Agents.MemoryContextTest do
  use Platform.DataCase, async: true

  alias Platform.Agents.{Agent, Context, MemoryContext}
  alias Platform.Repo

  defp create_agent(attrs \\ %{}) do
    default = %{
      slug: "agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Memory Agent",
      status: "active"
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  describe "upsert_workspace_file/4" do
    test "creates then updates a versioned workspace file" do
      agent = create_agent()

      assert {:ok, file} =
               MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "v1 soul")

      assert file.version == 1
      assert file.content == "v1 soul"

      assert {:ok, updated} =
               MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "v2 soul")

      assert updated.version == 2
      assert updated.content == "v2 soul"
    end

    test "returns stale error when expected_version does not match" do
      agent = create_agent()
      assert {:ok, file} = MemoryContext.upsert_workspace_file(agent.id, "AGENTS.md", "rules")

      assert {:error, :stale_workspace_file} =
               MemoryContext.upsert_workspace_file(agent.id, "AGENTS.md", "new rules",
                 expected_version: file.version + 1
               )
    end
  end

  describe "append_memory/4" do
    test "writes memories and emits telemetry" do
      agent = create_agent()

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :memory_written]])

      assert {:ok, memory} =
               MemoryContext.append_memory(agent.id, :daily, "daily note",
                 date: ~D[2026-03-15],
                 metadata: %{"source" => "test"}
               )

      assert memory.memory_type == "daily"
      assert memory.date == ~D[2026-03-15]
      assert memory.metadata == %{"source" => "test"}

      assert_receive {[:platform, :agent, :memory_written], ^ref, _measurements, meta}
      assert meta.agent_id == agent.id
      assert meta.memory_id == memory.id
      assert meta.memory_type == "daily"

      :telemetry.detach(ref)
    end
  end

  describe "list_memories/2 and recall_memories/3" do
    test "filters by type, date range, and query" do
      agent = create_agent()

      {:ok, _} =
        MemoryContext.append_memory(agent.id, :long_term, "The team prefers calm systems")

      {:ok, daily_keep} =
        MemoryContext.append_memory(
          agent.id,
          :daily,
          "Met with team to discuss calm platform rollout",
          date: ~D[2026-03-14]
        )

      {:ok, _daily_skip} =
        MemoryContext.append_memory(agent.id, :daily, "Unrelated gardening note",
          date: ~D[2026-03-10]
        )

      filtered =
        MemoryContext.list_memories(agent.id,
          memory_type: :daily,
          date_from: ~D[2026-03-12],
          query: "platform"
        )

      assert Enum.map(filtered, & &1.id) == [daily_keep.id]

      recalled = MemoryContext.recall_memories(agent.id, "calm")
      assert Enum.any?(recalled, &(&1.memory_type == "long_term"))
    end
  end

  describe "build_context/2" do
    test "assembles workspace files and memory buckets" do
      agent = create_agent()
      session_id = Ecto.UUID.generate()

      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady and sharp")
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "USER.md", "Operator prefers calm")
      {:ok, long_term} = MemoryContext.append_memory(agent.id, :long_term, "important preference")

      {:ok, daily} =
        MemoryContext.append_memory(agent.id, :daily, "today happened", date: ~D[2026-03-15])

      {:ok, snapshot} =
        MemoryContext.append_memory(agent.id, :snapshot, "session boundary snapshot")

      context =
        MemoryContext.build_context(agent.id,
          session_id: session_id,
          workspace_keys: ["SOUL.md", "USER.md"],
          daily_limit: 1,
          snapshot_limit: 1
        )

      assert %Context{} = context
      assert context.agent_id == agent.id
      assert context.session_id == session_id

      assert context.workspace == %{
               "SOUL.md" => "steady and sharp",
               "USER.md" => "Operator prefers calm"
             }

      assert Enum.map(context.memory.long_term, & &1.id) == [long_term.id]
      assert Enum.map(context.memory.daily, & &1.id) == [daily.id]
      assert Enum.map(context.memory.snapshot, & &1.id) == [snapshot.id]
    end

    test "applies query filter across loaded memory buckets" do
      agent = create_agent()

      {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "alpha memory")
      {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "beta memory")

      context = MemoryContext.build_context(agent.id, memory_types: [:long_term], query: "beta")

      assert Enum.map(context.memory.long_term, & &1.content) == ["beta memory"]
      refute Map.has_key?(context.memory, :daily)
    end
  end
end
