defmodule Platform.Chat.AttentionRouterTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message}
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "Zip reply: #{message}", model: "stub", usage: %{}}}
    end
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_pid = Application.get_env(:platform, :chat_agent_test_pid)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      Application.put_env(:platform, :chat_agent_test_pid, previous_pid)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    # Ensure ActiveAgentStore is running and sandbox-allowed
    store =
      Process.whereis(ActiveAgentStore) ||
        start_supervised!({ActiveAgentStore, []})

    Sandbox.allow(Repo, self(), store)

    :ok
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Rowan",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Zip",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    message
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  defp drain do
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  describe "DM spaces" do
    test "always routes to agent participant without mention" do
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "hey, what's up?"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey, what's up?", _opts}, 500
      drain()
    end
  end

  describe "execution spaces" do
    test "log_only messages return empty" do
      space = create_space(%{kind: "execution"})
      user = create_participant(space.id)
      agent = create_agent()
      Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "log entry", log_only: true})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 100
      drain()
    end
  end

  describe "single @mention" do
    test "sets active agent and routes to mentioned agent" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      # Add to roster as member
      Chat.add_space_agent(space.id, agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      # Verify active agent was set
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "hey @zip help me", _opts}, 500
      drain()
    end
  end

  describe "multi @mention" do
    test "routes to all mentioned agents and clears active" do
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      agent1 = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Nova"})

      {:ok, p1} = Chat.ensure_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, p2} = Chat.ensure_agent_participant(space.id, agent2, display_name: "Nova")

      Chat.add_space_agent(space.id, agent1.id, role: "principal")
      Chat.add_space_agent(space.id, agent2.id, role: "member")

      # Set one as active first to verify it gets cleared
      ActiveAgentStore.set_active(space.id, p1.id)

      message = create_message(space.id, user.id, %{content: "hey @zip and @nova help"})

      {:ok, decisions} = AttentionRouter.route(message)

      participant_ids = Enum.map(decisions, & &1.participant_id) |> Enum.sort()
      expected_ids = Enum.sort([p1.id, p2.id])
      assert participant_ids == expected_ids

      assert Enum.all?(decisions, fn d -> d.reason == :multi_mention end)

      # Active agent should be cleared
      assert ActiveAgentStore.get_active(space.id) == nil

      drain()
    end
  end

  describe "no mention + active agent" do
    test "routes to active agent and refreshes timeout" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      # Set as active agent (simulates prior @mention)
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      message = create_message(space.id, user.id, %{content: "and also do this"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :active_agent}]} =
               AttentionRouter.route(message)

      # Active agent should still be set
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "and also do this", _opts}, 500
      drain()
    end
  end

  describe "no mention + no active + watch ON + primary agent" do
    test "routes to primary agent and sets as active" do
      agent = create_agent(%{name: "Zip"})

      space =
        create_space(%{
          kind: "group",
          watch_enabled: true,
          primary_agent_id: agent.id
        })

      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      message = create_message(space.id, user.id, %{content: "hello everyone"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :watch}]} =
               AttentionRouter.route(message)

      # Agent should now be active
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "hello everyone", _opts}, 500
      drain()
    end
  end

  describe "no mention + no active + watch OFF" do
    test "returns empty (silence)" do
      space = create_space(%{kind: "channel", watch_enabled: false})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")
      Chat.add_space_agent(space.id, agent.id, role: "principal")

      message = create_message(space.id, user.id, %{content: "just chatting"})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end
  end

  describe "agent self-message filtering" do
    test "agent doesn't respond to its own messages in DM" do
      space = create_space(%{kind: "dm"})
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      agent_message =
        create_message(space.id, agent_participant.id, %{content: "I'm the agent speaking"})

      assert {:ok, []} = AttentionRouter.route(agent_message)
      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end
  end

  describe "resolve_attention_mode/2" do
    test "returns kind-based default for each space kind" do
      participant = %Platform.Chat.Participant{}

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "channel"},
               participant
             ) == "on_mention"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "dm"},
               participant
             ) == "directed"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "group"},
               participant
             ) == "collaborative"
    end
  end

  describe "mention → active agent → no mention flow" do
    test "mention sets active, followup routes via active_agent, watch routes primary" do
      agent = create_agent(%{name: "Zip"})

      space =
        create_space(%{
          kind: "channel",
          watch_enabled: true,
          primary_agent_id: agent.id
        })

      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")
      agent_participant_id = agent_participant.id

      # Step 1: @mention sets active agent
      mention = create_message(space.id, user.id, %{content: "@zip help me"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      # Step 2: followup without mention → routes via active_agent
      followup = create_message(space.id, user.id, %{content: "and also this"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :active_agent}]} =
               AttentionRouter.route(followup)

      # Step 3: clear active agent, next message should use watch
      ActiveAgentStore.clear_active(space.id)
      watch_msg = create_message(space.id, user.id, %{content: "new topic"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :watch}]} =
               AttentionRouter.route(watch_msg)

      drain()
    end
  end

  describe "stale active agent cleanup" do
    test "clears mutex and falls through to watch when active agent has left" do
      agent = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Zip2"})

      # Set agent2 as primary so watch mode picks it up after stale mutex clears
      space =
        create_space(%{
          kind: "group",
          watch_enabled: true,
          primary_agent_id: agent2.id
        })

      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      {:ok, agent2_participant} =
        Chat.ensure_agent_participant(space.id, agent2, display_name: "Zip2")

      Chat.add_space_agent(space.id, agent2.id, role: "member")

      # Set the first agent as active
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      # Mark the first agent participant as having left the space
      agent_participant
      |> Ecto.Changeset.change(%{left_at: DateTime.utc_now()})
      |> Repo.update!()

      # Send a message — should NOT silently drop; should clear stale mutex
      # and fall through to watch routing (which picks up agent2)
      message = create_message(space.id, user.id, %{content: "feedback for agent"})
      {:ok, decisions} = AttentionRouter.route(message)

      # The stale active agent mutex should have been cleared
      assert ActiveAgentStore.get_active(space.id) != agent_participant.id

      # Should have routed to agent2 via watch, not returned empty
      assert length(decisions) > 0

      drain()
    end

    test "keeps mutex when active agent is still present but authored the message" do
      space = create_space(%{kind: "channel"})
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      # Set agent as active
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      # Agent sends its own message — should NOT clear the mutex
      message =
        create_message(space.id, agent_participant.id, %{content: "I'm responding"})

      {:ok, decisions} = AttentionRouter.route(message)

      # No routing needed for self-message
      assert decisions == []

      # Mutex should still be set (agent is still an active participant)
      assert ActiveAgentStore.get_active(space.id) == agent_participant.id

      drain()
    end
  end
end
