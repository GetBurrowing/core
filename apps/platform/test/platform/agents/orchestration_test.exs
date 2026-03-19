defmodule Platform.Agents.OrchestrationTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{
    Agent,
    AgentServer,
    MemoryContext,
    Orchestration,
    Session
  }

  alias Platform.Repo

  defp create_agent(attrs) do
    default = %{
      slug: "orch-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Orchestration Agent",
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

  describe "spawn_child/4" do
    test "creates a child runtime/session, seeds workspace, and shares filtered context" do
      parent = create_agent(%{slug: "parent-#{System.unique_integer([:positive, :monotonic])}"})
      _parent_pid = start_agent!(parent)

      {:ok, _} = MemoryContext.upsert_workspace_file(parent.id, "SOUL.md", "steady")
      {:ok, _} = MemoryContext.upsert_workspace_file(parent.id, "USER.md", "Operator")
      {:ok, _} = MemoryContext.append_memory(parent.id, :long_term, "calm systems win")

      {:ok, parent_session, _} =
        AgentServer.start_session(parent.id, local: %{"goal" => "research context sharing"})

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :child_spawned]])

      assert {:ok, result} =
               Orchestration.spawn_child(parent.id, parent_session.id, %{
                 slug: "child-#{System.unique_integer([:positive, :monotonic])}",
                 name: "Researcher",
                 task: "Summarize orchestration design",
                 workspace: %{"SOUL.md" => "focused", "BRIEF.md" => "research brief"},
                 context_scope: %{
                   share: :custom,
                   include_keys: ["SOUL.md", "goal"],
                   include_memory: true,
                   include_workspace: true,
                   max_depth: 2
                 }
               })

      child_agent = result.agent
      child_session = result.session
      child_context = result.context

      assert child_agent.parent_agent_id == parent.id
      assert child_agent.workspace_id == parent.workspace_id
      assert %Session{} = child_session
      assert child_session.parent_session_id == parent_session.id
      assert child_context.workspace == %{"BRIEF.md" => "research brief", "SOUL.md" => "focused"}
      assert child_context.local["task"] == "Summarize orchestration design"
      assert child_context.metadata["task"] == "Summarize orchestration design"
      assert child_context.metadata["inheritance_depth"] == 1

      inherited = child_context.inherited[parent_session.id]
      assert inherited["workspace"] == %{"SOUL.md" => "steady"}
      assert inherited["local"] == %{"goal" => "research context sharing"}
      assert inherited["memory"]["long_term"] |> Enum.map(& &1["content"]) == ["calm systems win"]

      assert result.share_record.from_session_id == parent_session.id
      assert result.share_record.to_session_id == child_session.id
      assert result.created? == true
      assert is_pid(result.pid)
      assert AgentServer.whereis(child_agent.id) == result.pid

      assert_receive {[:platform, :agent, :child_spawned], ^ref, _measurements, meta}
      assert meta.parent_agent_id == parent.id
      assert meta.parent_session_id == parent_session.id
      assert meta.child_agent_id == child_agent.id
      assert meta.child_session_id == child_session.id
      assert meta.scope == "custom"
      assert meta.task == "Summarize orchestration design"

      listed_children = Orchestration.list_children(parent_session.id)

      assert Enum.any?(
               listed_children,
               &(&1.session.id == child_session.id && &1.agent.id == child_agent.id)
             )

      :telemetry.detach(ref)
    end
  end

  describe "complete_child/5" do
    test "promotes a child delta, writes a snapshot, and stops the child runtime when asked" do
      parent =
        create_agent(%{slug: "orch-parent-#{System.unique_integer([:positive, :monotonic])}"})

      _parent_pid = start_agent!(parent)

      {:ok, parent_session, _} =
        AgentServer.start_session(parent.id,
          local: %{"stale" => "remove-me", "existing" => "keep"}
        )

      assert {:ok, spawned} =
               Orchestration.spawn_child(parent.id, parent_session.id, %{
                 slug: "orch-child-#{System.unique_integer([:positive, :monotonic])}",
                 task: "Wrap up findings"
               })

      child_agent = spawned.agent
      child_session = spawned.session

      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :child_completed]])

      assert {:ok, result} =
               Orchestration.complete_child(
                 parent.id,
                 parent_session.id,
                 child_agent.id,
                 child_session.id,
                 delta: %{
                   additions: %{"summary" => "done", "nested" => %{"answer" => 42}},
                   removals: ["stale"],
                   memory_updates: [
                     %{
                       memory_type: :long_term,
                       content: "child insight",
                       metadata: %{"source" => "orchestration_test"}
                     }
                   ],
                   promote: true
                 },
                 snapshot: "child finished cleanly",
                 metadata: %{"source" => "orchestration_test"},
                 stop_agent: true
               )

      assert result.session.status == "completed"
      assert result.snapshot_memory.content == "child finished cleanly"

      assert result.promoted_context.local == %{
               "existing" => "keep",
               "summary" => "done",
               "nested" => %{"answer" => 42}
             }

      assert [memory] = result.promoted_memories
      assert memory.memory_type == "long_term"
      assert memory.content == "child insight"
      assert memory.metadata["promoted_from_agent"] == child_agent.id
      assert memory.metadata["promoted_from_session"] == child_session.id
      assert result.promotion_share.from_session_id == child_session.id
      assert result.promotion_share.to_session_id == parent_session.id
      assert result.stopped? == true

      assert {:ok, refreshed_parent_context} =
               AgentServer.session_context(parent.id, parent_session.id)

      assert refreshed_parent_context.local["summary"] == "done"
      refute Map.has_key?(refreshed_parent_context.local, "stale")

      assert AgentServer.whereis(child_agent.id) == nil

      assert_receive {[:platform, :agent, :child_completed], ^ref, measurements, meta}
      assert measurements.promoted_memories == 1
      assert meta.parent_agent_id == parent.id
      assert meta.parent_session_id == parent_session.id
      assert meta.child_agent_id == child_agent.id
      assert meta.child_session_id == child_session.id
      assert meta.status == "completed"
      assert meta.promoted == true
      assert meta.snapshot_written == true
      assert meta.stopped == true

      :telemetry.detach(ref)
    end
  end
end
