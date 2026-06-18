defmodule Platform.Chat.AttentionRouterTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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
      Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "log entry", log_only: true})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 100
      drain()
    end

    test "non-log steering routes to the assigned task agent even without an active mutex" do
      agent = create_agent(%{name: "Beacon"})
      {:ok, project} = Tasks.create_project(%{name: "Execution routing project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution routing task",
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)

      message = create_message(space.id, user.id, %{content: "are you still working?"})

      assert {:ok, [%{participant_id: agent_participant_id, reason: :watch}]} =
               AttentionRouter.route(message)

      assert is_binary(agent_participant_id)
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "are you still working?", _opts}, 500
      drain()
    end

    test "execution steering follows the current assignee when the mutex is stale after reassignment" do
      agent_one = create_agent(%{name: "Beacon"})
      agent_two = create_agent(%{name: "Nova"})
      {:ok, project} = Tasks.create_project(%{name: "Execution reassignment project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution reassignment task",
          status: "in_progress",
          assignee_id: agent_one.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)

      {:ok, participant_one} =
        Chat.add_agent_participant(space.id, agent_one, display_name: "Beacon")

      {:ok, participant_two} =
        Chat.add_agent_participant(space.id, agent_two, display_name: "Nova")

      participant_two_id = participant_two.id
      ActiveAgentStore.set_active(space.id, participant_one.id)

      {:ok, _task} =
        Tasks.update_task(task, %{assignee_id: agent_two.id, assignee_type: "agent"})

      message = create_message(space.id, user.id, %{content: "please pick up the new direction"})

      assert {:ok, [%{participant_id: ^participant_two_id, reason: :watch}]} =
               AttentionRouter.route(message)

      assert ActiveAgentStore.get_active(space.id) == participant_two_id

      assert_receive {:agent_chat_called, "please pick up the new direction", _opts}, 500
      drain()
    end

    test "execution steering rejoins a departed assignee participant instead of dropping feedback" do
      agent = create_agent(%{name: "Beacon"})
      {:ok, project} = Tasks.create_project(%{name: "Execution departed participant project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution departed participant task",
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)
      {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Beacon")

      participant_id = participant.id
      ActiveAgentStore.set_active(space.id, participant_id)

      # Hard-delete the participant to simulate dismissal (ADR 0038).
      {:ok, _} = Chat.remove_participant(participant)

      message = create_message(space.id, user.id, %{content: "are you still on this?"})

      # With the mutex holder gone, execution-space routing falls through to
      # the watch path, which re-activates the assignee.
      assert {:ok, [%{reason: reason}]} = AttentionRouter.route(message)
      assert reason in [:watch, :mention, :active_agent]
      # A fresh participant row was created by the execution-space add path.
      assert Chat.get_agent_participant(space.id, agent.id) != nil

      assert_receive {:agent_chat_called, "are you still on this?", _opts}, 500
      drain()
    end
  end

  describe "single @mention" do
    test "sets active agent and routes to mentioned agent" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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

      {:ok, p1} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, p2} = Chat.add_agent_participant(space.id, agent2, display_name: "Nova")

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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

      Chat.add_agent_participant(space.id, agent, display_name: "Zip")
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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      {:ok, agent2_participant} =
        Chat.add_agent_participant(space.id, agent2, display_name: "Zip2")

      Chat.add_space_agent(space.id, agent2.id, role: "member")

      # Set the first agent as active
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      # Dismiss the first agent (hard-delete post-ADR-0038)
      {:ok, _} = Chat.remove_participant(agent_participant)

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
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

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

  describe "bracketed @[Name] mentions (ADR 0037)" do
    test "routes on exact bracketed match with multi-word display name" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, agent.id, role: "member")

      message =
        create_message(space.id, user.id, %{content: "hey @[Rowan Ellis] can you look"})

      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "bracketed @[Rowan] does not leak to @[Rowan Ellis] (no prefix ambiguity)" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)

      rowan_agent = create_agent(%{name: "Rowan"})
      rowan_m_agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, rowan_participant} =
        Chat.add_agent_participant(space.id, rowan_agent, display_name: "Rowan")

      {:ok, _rowan_m_participant} =
        Chat.add_agent_participant(space.id, rowan_m_agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, rowan_agent.id, role: "member")
      Chat.add_space_agent(space.id, rowan_m_agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @[Rowan] look here"})

      rowan_participant_id = rowan_participant.id

      # Only Rowan is routed — Rowan Ellis's participant must not appear.
      assert {:ok, [%{participant_id: ^rowan_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "legacy @name still routes in a pre-migration message" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "hybrid message: bracketed + legacy both route" do
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      zip = create_agent(%{name: "Zip"})
      nova = create_agent(%{name: "Nova"})

      {:ok, zip_p} = Chat.add_agent_participant(space.id, zip, display_name: "Zip")
      {:ok, nova_p} = Chat.add_agent_participant(space.id, nova, display_name: "Nova")

      Chat.add_space_agent(space.id, zip.id, role: "member")
      Chat.add_space_agent(space.id, nova.id, role: "member")

      # User autocompletes Zip → bracketed; types @nova manually → legacy.
      message =
        create_message(space.id, user.id, %{content: "ping @[Zip] and also @nova please"})

      {:ok, decisions} = AttentionRouter.route(message)

      participant_ids = decisions |> Enum.map(& &1.participant_id) |> Enum.sort()
      assert participant_ids == Enum.sort([zip_p.id, nova_p.id])
      assert Enum.all?(decisions, fn d -> d.reason == :multi_mention end)

      drain()
    end

    test "@[Rowan Ellis] does not route to a legacy Rowan substring-match" do
      # Regression guard: ensure `@Rowan` substring inside `@[Rowan Ellis]`
      # does not leak into the legacy zone. Without stripping brackets first,
      # a plain-Rowan participant would be falsely routed.
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)

      rowan_agent = create_agent(%{name: "Rowan"})
      rowan_m_agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, _rowan_p} = Chat.add_agent_participant(space.id, rowan_agent, display_name: "Rowan")

      {:ok, rowan_m_p} =
        Chat.add_agent_participant(space.id, rowan_m_agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, rowan_agent.id, role: "member")
      Chat.add_space_agent(space.id, rowan_m_agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hello @[Rowan Ellis]"})

      rowan_m_p_id = rowan_m_p.id

      assert {:ok, [%{participant_id: ^rowan_m_p_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end
  end

  # ── Parser-level unit tests (Stage 1 of @here notifications) ───────────────
  #
  # These exercise `extract_mention_tokens/1` and the back-compat shape of
  # `extract_bracketed_tokens/1`. No DB, no router pipeline — just the
  # tokenizer that the later fan-out / push / UI stages build on.

  describe "extract_mention_tokens/1 — @[here] broadcast sentinel" do
    test "recognizes @[here] at the start of a message" do
      assert AttentionRouter.extract_mention_tokens("@[here] heads up") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "recognizes @[here] in the middle of a message" do
      assert AttentionRouter.extract_mention_tokens("hey folks @[here] check this") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "recognizes @[here] immediately after punctuation" do
      assert AttentionRouter.extract_mention_tokens("status:@[here] update?") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "returns two tokens when @[here] appears twice (dedup is fan-out's job)" do
      tokens = AttentionRouter.extract_mention_tokens("@[here] and again @[here]")

      assert tokens == [
               %{kind: :broadcast, target: :here},
               %{kind: :broadcast, target: :here}
             ]
    end

    test "distinguishes @[here] from an adjacent @[Name] mention" do
      tokens =
        AttentionRouter.extract_mention_tokens("ping @[Rowan Ellis] also @[here] please")

      assert tokens == [
               %{kind: :name, value: "Rowan Ellis"},
               %{kind: :broadcast, target: :here}
             ]
    end

    test "trailing space inside brackets is a name token, not a broadcast" do
      # `@[here ]` keeps whitespace significant — treat as a name token so
      # the broadcast classifier stays strict.
      assert AttentionRouter.extract_mention_tokens("@[here ] hello") ==
               [%{kind: :name, value: "here "}]
    end

    test "@[HERE] (uppercase) is a name token, not a broadcast" do
      # Case-insensitivity is a deferred follow-up. For now only the literal
      # lowercase form is special.
      assert AttentionRouter.extract_mention_tokens("@[HERE] hello") ==
               [%{kind: :name, value: "HERE"}]
    end

    test "@[Here] (title case) is a name token, not a broadcast" do
      assert AttentionRouter.extract_mention_tokens("@[Here] hello") ==
               [%{kind: :name, value: "Here"}]
    end

    test "@[hereish] (substring) is a name token, not a broadcast" do
      assert AttentionRouter.extract_mention_tokens("@[hereish] hello") ==
               [%{kind: :name, value: "hereish"}]
    end

    test "returns an empty list when no bracketed tokens are present" do
      assert AttentionRouter.extract_mention_tokens("plain message with no mentions") == []
    end

    test "preserves source order across mixed token kinds" do
      tokens =
        AttentionRouter.extract_mention_tokens(
          "@[here] first then @[Zip] then @[here] then @[Nova]"
        )

      assert tokens == [
               %{kind: :broadcast, target: :here},
               %{kind: :name, value: "Zip"},
               %{kind: :broadcast, target: :here},
               %{kind: :name, value: "Nova"}
             ]
    end

    test "non-binary input returns an empty list" do
      assert AttentionRouter.extract_mention_tokens(nil) == []
      assert AttentionRouter.extract_mention_tokens(123) == []
    end
  end

  # ── Fan-out tests (Stage 2 of @here notifications) ─────────────────────────
  #
  # These exercise the routing pipeline end-to-end: a message containing
  # `@[here]` must produce one `:here` decision per human recipient,
  # excluding the sender, regardless of per-participant attention_mode.
  # Agent routing remains under the mutex pipeline and is unaffected.

  describe "do_route/1 — @[here] fan-out" do
    test "5-human-1-agent channel fans out :here to all humans except sender" do
      space = create_space(%{kind: "channel"})

      sender = create_participant(space.id, %{display_name: "Sender"})

      _h2 =
        create_participant(space.id, %{
          display_name: "Alice",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      _h3 =
        create_participant(space.id, %{
          display_name: "Bob",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "all"
        })

      _h4 =
        create_participant(space.id, %{
          display_name: "Carol",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "active"
        })

      _h5 =
        create_participant(space.id, %{
          display_name: "Dan",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "heartbeat"
        })

      agent = create_agent(%{name: "Zip"})
      {:ok, _agent_p} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, sender.id, %{content: "team check-in @[here]"})

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))

      assert length(here_decisions) == 4,
             "expected 4 :here decisions for the 4 non-sender humans, got #{inspect(decisions)}"

      here_pids = here_decisions |> Enum.map(& &1.participant_id) |> Enum.sort()

      participants =
        Platform.Repo.all(
          from(p in Platform.Chat.Participant,
            where: p.space_id == ^space.id and p.participant_type == "user"
          )
        )

      expected_pids =
        participants
        |> Enum.reject(&(&1.id == sender.id))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert here_pids == expected_pids
      refute Enum.any?(here_decisions, &(&1.participant_id == sender.id))

      # Agent decisions are independent of @[here] — no :here for the agent.
      agent_decisions = Enum.reject(decisions, &(&1.reason == :here))
      refute Enum.any?(agent_decisions, &(&1.reason == :here))

      drain()
    end

    test "agent-only channel (no humans) emits zero :here decisions" do
      space = create_space(%{kind: "group"})

      agent1 = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Nova"})
      {:ok, sender} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, _other_agent} = Chat.add_agent_participant(space.id, agent2, display_name: "Nova")

      message = create_message(space.id, sender.id, %{content: "broadcast @[here]"})

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.filter(decisions, &(&1.reason == :here)) == [],
             "expected no :here decisions when there are no human recipients"

      drain()
    end

    test "heartbeat-mode human still gets a :here decision (override), not ETS-queued" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      heartbeat_user =
        create_participant(space.id, %{
          display_name: "Heartbeat User",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "heartbeat"
        })

      message = create_message(space.id, sender.id, %{content: "ping @[here]"})

      heartbeat_pid = heartbeat_user.id

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.any?(decisions, fn d ->
               d.participant_id == heartbeat_pid and d.reason == :here
             end),
             "heartbeat-mode user must receive :here decision, got #{inspect(decisions)}"

      # ETS heartbeat queue should NOT have been populated for this signal —
      # the dispatch loop only queues `:heartbeat`, never `:here`.
      assert AttentionRouter.pending(heartbeat_pid) == []

      drain()
    end

    test "mention-mode human gets :here decision without self-name match" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      # Their display name does NOT appear in the message — under the
      # ordinary "mention" path they'd be silenced. @[here] overrides that.
      mention_user =
        create_participant(space.id, %{
          display_name: "Quiet Person",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      message =
        create_message(space.id, sender.id, %{content: "no name here, just @[here] please"})

      mention_pid = mention_user.id

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.any?(decisions, fn d ->
               d.participant_id == mention_pid and d.reason == :here
             end),
             "mention-mode user must receive :here override decision, got #{inspect(decisions)}"

      drain()
    end

    test "duplicate @[here] @[here] still produces exactly one decision per human" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      _h2 =
        create_participant(space.id, %{
          display_name: "Alice",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      _h3 =
        create_participant(space.id, %{
          display_name: "Bob",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "all"
        })

      message =
        create_message(space.id, sender.id, %{content: "@[here] and again @[here] please"})

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))

      here_pids = Enum.map(here_decisions, & &1.participant_id)

      assert length(here_pids) == length(Enum.uniq(here_pids)),
             "expected dedup per participant_id"

      assert length(here_decisions) == 2, "expected one decision per non-sender human"

      drain()
    end

    # V2 (e2e_behavior task 019edbbf, validation 019edbc2-991d-7a9c-8a7e-5a295744e32d):
    # When `@[here]` and a named `@[Name]` co-occur in one message, the named
    # recipient must receive BOTH a `:here` broadcast AND a `:mention`
    # decision. Other non-sender humans receive only `:here`. Agents are
    # untouched by the broadcast. Duplicate `@[here]` tokens dedupe to one
    # `:here` per participant. Sender is never in any decision.
    test "mixed @[here] + @[Name] produces :here per human plus a :mention for the named recipient" do
      space = create_space(%{kind: "channel"})

      rowan =
        create_participant(space.id, %{
          display_name: "Rowan",
          attention_mode: "mention"
        })

      alex =
        create_participant(space.id, %{
          display_name: "Alex",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      sam =
        create_participant(space.id, %{
          display_name: "Sam",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      harper =
        create_participant(space.id, %{
          display_name: "Harper",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      taylor =
        create_participant(space.id, %{
          display_name: "Taylor",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      higgins_agent = create_agent(%{name: "Higgins"})
      geordi_agent = create_agent(%{name: "Geordi"})

      {:ok, _higgins_p} =
        Chat.add_agent_participant(space.id, higgins_agent, display_name: "Higgins")

      {:ok, _geordi_p} =
        Chat.add_agent_participant(space.id, geordi_agent, display_name: "Geordi")

      message =
        create_message(space.id, rowan.id, %{
          content:
            "@[here] kickoff in 10! Reminder: @[here], grab coffee. Also @[Alex] sync after. @[here]"
        })

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))
      mention_decisions = Enum.filter(decisions, &(&1.reason == :mention))

      # 4 :here decisions — one per non-sender human (alex, sam, harper, taylor),
      # despite the message containing three `@[here]` tokens.
      assert length(here_decisions) == 4,
             "expected 4 :here decisions (one per non-sender human), got #{inspect(decisions)}"

      here_pids = here_decisions |> Enum.map(& &1.participant_id) |> Enum.sort()

      expected_here_pids =
        [alex.id, sam.id, harper.id, taylor.id] |> Enum.sort()

      assert here_pids == expected_here_pids,
             "here_pids should be alex/sam/harper/taylor, got #{inspect(here_pids)}"

      # 1 :mention decision — for Alex only (the only named human).
      assert length(mention_decisions) == 1,
             "expected exactly one :mention decision (for Alex), got #{inspect(mention_decisions)}"

      assert hd(mention_decisions).participant_id == alex.id,
             ":mention must target Alex, got #{inspect(mention_decisions)}"

      # Alex appears in BOTH lists — the planner expected duplication, not dedup.
      alex_decisions = Enum.filter(decisions, &(&1.participant_id == alex.id))

      assert length(alex_decisions) == 2,
             "Alex must appear in both :here and :mention, got #{inspect(alex_decisions)}"

      assert Enum.any?(alex_decisions, &(&1.reason == :here))
      assert Enum.any?(alex_decisions, &(&1.reason == :mention))

      # Sender (rowan) is never in any decision.
      refute Enum.any?(decisions, &(&1.participant_id == rowan.id)),
             "sender rowan must not appear in decisions"

      # Agents receive zero :here (broadcast is humans-only).
      higgins_participant = Chat.get_agent_participant(space.id, higgins_agent.id)
      geordi_participant = Chat.get_agent_participant(space.id, geordi_agent.id)

      refute Enum.any?(decisions, fn d ->
               d.reason == :here and
                 d.participant_id in [higgins_participant.id, geordi_participant.id]
             end),
             "agents must receive zero :here decisions"

      # Total decision count = 4 :here + 1 :mention (+ agent routing, which
      # may add up to 0–2 entries depending on watch/mutex state but never
      # :here or :mention since the message has no agent @[Name] tokens
      # and no roster is configured).
      human_decision_count = length(here_decisions) + length(mention_decisions)

      assert human_decision_count == 5,
             "expected 5 human decisions (4 :here + 1 :mention), got #{human_decision_count}"

      drain()
    end
  end

  # ── Push title tests (Stage 3 of @here notifications) ─────────────────────
  #
  # Pure-helper coverage. The actual `Platform.Push.send_notification/2`
  # call short-circuits under `:test` (see maybe_send_push/4) to avoid
  # racing against Ecto sandbox teardown, so we test the title-builder
  # in isolation. That's enough — `maybe_send_push/4` does nothing more
  # than pass the helper output through.

  describe "notification_title/2" do
    test "for :here, surfaces the @here broadcast context in the title" do
      assert AttentionRouter.notification_title("Rowan", :here) == "Rowan @here in Suite"
    end

    test "for :mention, uses the default sender-only title" do
      assert AttentionRouter.notification_title("Rowan", :mention) == "Rowan in Suite"
    end

    test "for :all, uses the default sender-only title" do
      assert AttentionRouter.notification_title("Rowan", :all) == "Rowan in Suite"
    end

    test "for any other reason atom, uses the default sender-only title" do
      # Defensive: future reasons (e.g. :directed, :watch, :active_agent)
      # should fall through to the default rather than crash.
      for reason <- [:directed, :watch, :active_agent, :active, :multi_mention] do
        assert AttentionRouter.notification_title("Rowan", reason) == "Rowan in Suite",
               "expected default title for reason #{inspect(reason)}"
      end
    end
  end

  describe "extract_bracketed_tokens/1 back-compat with @[here]" do
    test "filters out the @[here] sentinel from the name token list" do
      # Existing callers (e.g. `Chat.reinvite_mentioned_agents`) consume the
      # token list to look up agents by display name. If `here` leaked
      # through, an agent literally named "here" could be mistakenly
      # resurrected on every broadcast.
      {tokens, _legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("@[here] please @[Rowan Ellis]")

      assert tokens == ["Rowan Ellis"]
    end

    test "still strips the @[here] form from the legacy_zone" do
      # The legacy zone is fed to the substring-match path; we don't want
      # `@here` to fall through and accidentally match a legacy `@here`.
      {_tokens, legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("hi @[here] then keep going")

      refute String.contains?(legacy_zone, "@[")
      refute String.contains?(legacy_zone, "@here")
    end

    test "name-only message round-trips unchanged" do
      {tokens, legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("hey @[Zip] take a look")

      assert tokens == ["Zip"]
      refute String.contains?(legacy_zone, "@[")
    end
  end
end
