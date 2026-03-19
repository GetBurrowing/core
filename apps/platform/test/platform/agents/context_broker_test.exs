defmodule Platform.Agents.ContextBrokerTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{
    Agent,
    AgentServer,
    ContextBroker,
    ContextDelta,
    ContextShare,
    MemoryContext
  }

  alias Platform.Repo

  defp create_agent(attrs) do
    default = %{
      slug: "ctx-broker-#{System.unique_integer([:positive, :monotonic])}",
      name: "Context Broker Agent",
      status: "active",
      max_concurrent: 2,
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  defp start_agent!(agent) do
    {:ok, pid} = AgentServer.start_agent(agent)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    on_exit(fn ->
      AgentServer.stop_agent(agent)
    end)

    pid
  end

  describe "share_context/5" do
    test "copies a filtered parent snapshot into the child and records provenance" do
      parent = create_agent(%{slug: "parent-#{System.unique_integer([:positive, :monotonic])}"})
      child = create_agent(%{slug: "child-#{System.unique_integer([:positive, :monotonic])}"})

      {:ok, _} = MemoryContext.upsert_workspace_file(parent.id, "SOUL.md", "steady")
      {:ok, _} = MemoryContext.upsert_workspace_file(parent.id, "USER.md", "Operator")
      {:ok, _} = MemoryContext.append_memory(parent.id, :long_term, "calm systems win")

      _parent_pid = start_agent!(parent)
      _child_pid = start_agent!(child)

      {:ok, parent_session, _} =
        AgentServer.start_session(parent.id, local: %{"task" => "research"})

      {:ok, child_session, _} = AgentServer.start_session(child.id)

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :context_shared]])

      {:ok, scope} =
        Platform.Agents.ContextScope.new(%{
          share: :custom,
          include_keys: ["SOUL.md", "task"],
          include_memory: true,
          include_workspace: true,
          max_depth: 2
        })

      assert {:ok, child_context, share_record} =
               ContextBroker.share_context(
                 parent.id,
                 parent_session.id,
                 child.id,
                 child_session.id,
                 scope
               )

      assert %ContextShare{} = share_record
      assert share_record.from_session_id == parent_session.id
      assert share_record.to_session_id == child_session.id
      assert share_record.scope == "custom"

      inherited = child_context.inherited[parent_session.id]
      assert inherited["workspace"] == %{"SOUL.md" => "steady"}
      assert inherited["local"] == %{"task" => "research"}

      assert inherited["memory"]["long_term"]
             |> Enum.map(& &1["content"]) == ["calm systems win"]

      assert child_context.metadata["inheritance_depth"] == 1
      assert child_context.metadata["last_inherited_from"] == parent_session.id

      assert {:ok, refreshed_child_context} =
               AgentServer.session_context(child.id, child_session.id)

      assert refreshed_child_context.inherited[parent_session.id]["workspace"] == %{
               "SOUL.md" => "steady"
             }

      assert_receive {[:platform, :agent, :context_shared], ^ref, _measurements, meta}
      assert meta.from_session_id == parent_session.id
      assert meta.to_session_id == child_session.id
      assert meta.scope == "custom"

      :telemetry.detach(ref)
    end
  end

  describe "promote_delta/3" do
    test "merges child additions into the parent and appends promoted memories" do
      parent =
        create_agent(%{slug: "promote-parent-#{System.unique_integer([:positive, :monotonic])}"})

      child =
        create_agent(%{slug: "promote-child-#{System.unique_integer([:positive, :monotonic])}"})

      _parent_pid = start_agent!(parent)
      _child_pid = start_agent!(child)

      {:ok, parent_session, _} =
        AgentServer.start_session(parent.id,
          local: %{"stale" => "remove-me", "existing" => "keep"}
        )

      {:ok, child_session, _} = AgentServer.start_session(child.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :context_promoted]])

      {:ok, delta} =
        ContextDelta.new(%{
          from_agent: child.id,
          from_session: child_session.id,
          additions: %{"summary" => "done", "nested" => %{"answer" => 42}},
          removals: ["stale"],
          memory_updates: [
            %{
              memory_type: :long_term,
              content: "child insight",
              metadata: %{"source" => "context_broker_test"}
            }
          ],
          promote: true
        })

      assert {:ok, promoted_context, [memory], share_record} =
               ContextBroker.promote_delta(parent.id, parent_session.id, delta)

      assert promoted_context.local == %{
               "existing" => "keep",
               "summary" => "done",
               "nested" => %{"answer" => 42}
             }

      assert promoted_context.metadata["last_promoted_from_agent"] == child.id
      assert promoted_context.metadata["last_promoted_from_session"] == child_session.id

      assert memory.memory_type == "long_term"
      assert memory.content == "child insight"
      assert memory.metadata["promoted_from_agent"] == child.id
      assert memory.metadata["promoted_from_session"] == child_session.id

      assert %ContextShare{} = share_record
      assert share_record.from_session_id == child_session.id
      assert share_record.to_session_id == parent_session.id
      assert share_record.scope == "custom"
      assert share_record.scope_filter["promotion"] == true

      assert {:ok, refreshed_parent_context} =
               AgentServer.session_context(parent.id, parent_session.id)

      assert refreshed_parent_context.local["summary"] == "done"
      refute Map.has_key?(refreshed_parent_context.local, "stale")

      assert_receive {[:platform, :agent, :context_promoted], ^ref, measurements, meta}
      assert measurements.memory_updates == 1
      assert meta.parent_session_id == parent_session.id
      assert meta.from_session_id == child_session.id

      :telemetry.detach(ref)
    end

    test "returns skipped when the child does not request promotion" do
      parent =
        create_agent(%{slug: "skip-parent-#{System.unique_integer([:positive, :monotonic])}"})

      child =
        create_agent(%{slug: "skip-child-#{System.unique_integer([:positive, :monotonic])}"})

      _parent_pid = start_agent!(parent)
      _child_pid = start_agent!(child)

      {:ok, parent_session, _} = AgentServer.start_session(parent.id)
      {:ok, child_session, _} = AgentServer.start_session(child.id)

      assert {:ok, :skipped} =
               ContextBroker.promote_delta(parent.id, parent_session.id, %{
                 from_agent: child.id,
                 from_session: child_session.id,
                 additions: %{"noop" => true},
                 promote: false
               })
    end
  end
end
