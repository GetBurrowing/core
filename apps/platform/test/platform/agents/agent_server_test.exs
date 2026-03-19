defmodule Platform.Agents.AgentServerTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{Agent, AgentServer, Session}
  alias Platform.Repo

  defp create_agent(attrs \\ %{}) do
    default = %{
      slug: "agent-server-#{System.unique_integer([:positive, :monotonic])}",
      name: "Agent Server",
      status: "active",
      max_concurrent: 1,
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

  describe "start_agent/2 and state/1" do
    test "boots a registered runtime and loads workspace files" do
      agent = create_agent()

      {:ok, _} =
        Platform.Agents.MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady")

      {:ok, _} =
        Platform.Agents.MemoryContext.upsert_workspace_file(agent.id, "USER.md", "Operator")

      pid = start_agent!(agent)

      assert is_pid(pid)
      assert AgentServer.whereis(agent.id) == pid
      assert AgentServer.whereis(agent.slug) == pid

      assert {:ok, state} = AgentServer.state(agent.id)
      assert state.agent_id == agent.id
      assert state.slug == agent.slug
      assert state.status == :idle
      assert state.workspace == %{"SOUL.md" => "steady", "USER.md" => "Operator"}
      assert state.active_context.workspace == %{"SOUL.md" => "steady", "USER.md" => "Operator"}

      assert {:ok, same_pid} = AgentServer.start_agent(agent.id)
      assert same_pid == pid
    end
  end

  describe "start_session/2" do
    test "persists a running session with a built context and enforces max concurrency" do
      agent = create_agent()

      {:ok, _} =
        Platform.Agents.MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady")

      {:ok, _} =
        Platform.Agents.MemoryContext.append_memory(agent.id, :long_term, "calm systems win")

      _pid = start_agent!(agent)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :session_started]])

      assert {:ok, session, context} = AgentServer.start_session(agent.id, query: "calm")
      assert %Session{} = session
      assert session.status == "running"
      assert context.agent_id == agent.id
      assert context.session_id == session.id
      assert context.workspace == %{"SOUL.md" => "steady"}
      assert Enum.map(context.memory.long_term, & &1.content) == ["calm systems win"]

      persisted = Repo.get!(Session, session.id)
      assert persisted.context_snapshot["workspace"] == %{"SOUL.md" => "steady"}

      assert persisted.context_snapshot["memory"]["long_term"] |> Enum.map(& &1["content"]) == [
               "calm systems win"
             ]

      assert_receive {[:platform, :agent, :session_started], ^ref, _measurements, meta}
      assert meta.agent_id == agent.id
      assert meta.session_id == session.id

      assert {:error, :max_concurrency} = AgentServer.start_session(agent.id)

      :telemetry.detach(ref)
    end

    test "returns paused for agents that are not runnable" do
      agent = create_agent(%{status: "paused"})
      _pid = start_agent!(agent)

      assert {:error, :paused} = AgentServer.start_session(agent.id)
    end
  end

  describe "finish_session/3" do
    test "completes a session, writes snapshot memory, and updates runtime state" do
      agent = create_agent()
      _pid = start_agent!(agent)
      {:ok, session, _context} = AgentServer.start_session(agent.id, local: %{"task" => "ship"})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :agent, :session_ended]])

      assert {:ok, finished, snapshot_memory} =
               AgentServer.finish_session(agent.id, session.id,
                 model_used: "anthropic/claude-sonnet-4-6",
                 token_usage: %{"total" => 42},
                 snapshot: "session wrapped",
                 local: %{"result" => "ok"},
                 metadata: %{"source" => "test"}
               )

      assert finished.status == "completed"
      assert finished.model_used == "anthropic/claude-sonnet-4-6"
      assert finished.token_usage == %{"total" => 42}
      assert %Platform.Agents.Memory{} = snapshot_memory
      assert snapshot_memory.memory_type == "snapshot"
      assert snapshot_memory.content == "session wrapped"
      assert snapshot_memory.metadata["session_id"] == session.id

      persisted = Repo.get!(Session, session.id)
      assert persisted.ended_at
      assert persisted.status == "completed"

      assert {:ok, []} = AgentServer.active_session_ids(agent.id)
      assert {:ok, state} = AgentServer.state(agent.id)
      assert state.status == :idle
      assert state.active_context.local == %{"task" => "ship", "result" => "ok"}
      assert state.active_context.metadata["source"] == "test"

      assert_receive {[:platform, :agent, :session_ended], ^ref, measurements, meta}
      assert measurements.duration_ms >= 0
      assert meta.agent_id == agent.id
      assert meta.session_id == session.id
      assert meta.snapshot_written == true

      :telemetry.detach(ref)
    end

    test "allows finishing a session without optional token usage" do
      agent = create_agent()
      _pid = start_agent!(agent)
      {:ok, session, _context} = AgentServer.start_session(agent.id)

      assert {:ok, finished, nil} = AgentServer.finish_session(agent.id, session.id)

      assert finished.status == "completed"
      assert finished.token_usage == %{}

      persisted = Repo.get!(Session, session.id)
      assert persisted.status == "completed"
      assert persisted.token_usage == %{}
    end
  end

  describe "fetch_credential/3" do
    test "uses agent-scoped Vault access" do
      agent = create_agent()
      slug = "agent-secret-#{System.unique_integer([:positive, :monotonic])}"

      {:ok, _credential} =
        Platform.Vault.put(slug, :oauth2, "super-secret",
          scope: {:agent, agent.id},
          provider: "anthropic"
        )

      _pid = start_agent!(agent)

      assert {:ok, "super-secret"} = AgentServer.fetch_credential(agent.id, slug)

      assert :ok =
               Platform.Vault.delete(slug, accessor: {:agent, agent.id})
               |> then(fn {:ok, _} -> :ok end)
    end
  end
end
