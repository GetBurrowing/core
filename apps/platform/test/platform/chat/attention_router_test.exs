defmodule Platform.Chat.AttentionRouterTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message}
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

  describe "space-level attention mode defaults" do
    test "DM space routes all messages to agent without @mention (directed mode)" do
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

    test "channel space routes only @mentions (on_mention default)" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      # No mention — should not route to agent
      message = create_message(space.id, user.id, %{content: "just chatting"})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200

      # With mention — should route
      mention = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert_receive {:agent_chat_called, "hey @zip help me", _opts}, 500
      drain()
    end

    test "group space with explicit agent_attention='directed' routes all messages" do
      space = create_space(%{kind: "group", agent_attention: "directed"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "no mention needed"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "no mention needed", _opts}, 500
      drain()
    end

    test "space with agent_attention=nil falls back to kind-based default" do
      # Channel with nil agent_attention → on_mention
      channel = create_space(%{kind: "channel", agent_attention: nil})
      user = create_participant(channel.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(channel.id, agent, display_name: "Zip")

      message = create_message(channel.id, user.id, %{content: "no mention"})
      assert {:ok, []} = AttentionRouter.route(message)

      # DM with nil agent_attention → directed
      dm = create_space(%{kind: "dm", agent_attention: nil})
      user2 = create_participant(dm.id)

      {:ok, dm_agent_participant} =
        Chat.ensure_agent_participant(dm.id, agent, display_name: "Zip")

      dm_message = create_message(dm.id, user2.id, %{content: "no mention"})
      dm_agent_id = dm_agent_participant.id

      assert {:ok, [%{participant_id: ^dm_agent_id, reason: :directed}]} =
               AttentionRouter.route(dm_message)

      drain()
    end
  end

  describe "sticky engagement" do
    test "after @mention → next message routes without mention → timeout expires → no longer routes" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      agent_participant_id = agent_participant.id

      # Step 1: @mention triggers agent reply, which calls engage_agent
      mention = create_message(space.id, user.id, %{content: "@zip help me"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert_receive {:agent_chat_called, "@zip help me", _opts}, 500

      # Agent should now be engaged
      state = Chat.get_attention_state(space.id, agent_participant.id)
      assert state.state == "engaged"

      # Step 2: Next message without mention should route via sticky engagement
      followup = create_message(space.id, user.id, %{content: "and also do this"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :sticky}]} =
               AttentionRouter.route(followup)

      assert_receive {:agent_chat_called, "and also do this", _opts}, 500

      # Step 3: Simulate timeout by setting engaged_since to the past
      Chat.upsert_attention_state(space.id, %{
        agent_participant_id: agent_participant.id,
        engaged_since: DateTime.add(DateTime.utc_now(), -700, :second)
      })

      # Now the engagement should have expired
      expired_msg = create_message(space.id, user.id, %{content: "still there?"})
      assert {:ok, []} = AttentionRouter.route(expired_msg)
      refute_receive {:agent_chat_called, _, _}, 200

      drain()
    end
  end

  describe "silencing" do
    test "natural language 'quiet' silences agent → re-mention unsilences" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      agent_participant_id = agent_participant.id

      # First, engage the agent so it's responding
      Chat.engage_agent(space.id, agent_participant.id, "test")

      # Silence via natural language
      silence_msg = create_message(space.id, user.id, %{content: "ok quiet now"})
      assert {:ok, []} = AttentionRouter.route(silence_msg)
      refute_receive {:agent_chat_called, _, _}, 200

      # Confirm silenced state
      state = Chat.get_attention_state(space.id, agent_participant.id)
      assert state.state == "silenced"

      # Regular message should not route
      normal_msg = create_message(space.id, user.id, %{content: "hello?"})
      assert {:ok, []} = AttentionRouter.route(normal_msg)
      refute_receive {:agent_chat_called, _, _}, 200

      # Re-mention should unsilence and route
      remention = create_message(space.id, user.id, %{content: "@zip come back"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(remention)

      assert_receive {:agent_chat_called, "@zip come back", _opts}, 500

      # Agent should be unsilenced now
      state = Chat.get_attention_state(space.id, agent_participant.id)
      assert state.state != "silenced"

      drain()
    end

    test "silence patterns are detected correctly" do
      assert AttentionRouter.silence_detected?("ok shut up")
      assert AttentionRouter.silence_detected?("that's all")
      assert AttentionRouter.silence_detected?("be quiet please")
      assert AttentionRouter.silence_detected?("only when mentioned")
      assert AttentionRouter.silence_detected?("thanks that's all")
      refute AttentionRouter.silence_detected?("help me with this")
      refute AttentionRouter.silence_detected?("can you explain?")
      refute AttentionRouter.silence_detected?(nil)
    end
  end

  describe "agent self-message filtering" do
    test "agent doesn't respond to its own messages in directed mode" do
      space = create_space(%{kind: "dm"})
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      # Agent posting its own message should not trigger routing to itself
      agent_message =
        create_message(space.id, agent_participant.id, %{content: "I'm the agent speaking"})

      assert {:ok, []} = AttentionRouter.route(agent_message)
      refute_receive {:agent_chat_called, _, _}, 200

      drain()
    end
  end

  describe "resolve_attention_mode/2" do
    test "returns space-level mode when set" do
      space = %Platform.Chat.Space{kind: "channel", agent_attention: "directed"}
      participant = %Platform.Chat.Participant{}

      assert AttentionRouter.resolve_attention_mode(space, participant) == "directed"
    end

    test "falls back to kind-based default when agent_attention is nil" do
      participant = %Platform.Chat.Participant{}

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "channel", agent_attention: nil},
               participant
             ) == "on_mention"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "dm", agent_attention: nil},
               participant
             ) == "directed"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "group", agent_attention: nil},
               participant
             ) == "collaborative"
    end
  end

  describe "attention state context functions" do
    test "engage_agent creates/updates attention state" do
      space = create_space()
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      assert Chat.get_attention_state(space.id, agent_participant.id) == nil

      {:ok, state} = Chat.engage_agent(space.id, agent_participant.id, "test context")
      assert state.state == "engaged"
      assert state.engaged_context == "test context"
      assert state.engaged_since != nil
    end

    test "disengage_agent returns to idle" do
      space = create_space()
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      Chat.engage_agent(space.id, agent_participant.id, "engaged")
      {:ok, state} = Chat.disengage_agent(space.id, agent_participant.id)

      assert state.state == "idle"
      assert state.engaged_since == nil
    end

    test "silence_agent and unsilence_agent" do
      space = create_space()
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      until = DateTime.add(DateTime.utc_now(), 1800, :second)
      {:ok, state} = Chat.silence_agent(space.id, agent_participant.id, until)
      assert state.state == "silenced"
      assert state.silenced_until != nil

      {:ok, state} = Chat.unsilence_agent(space.id, agent_participant.id)
      assert state.state == "idle"
    end
  end
end
