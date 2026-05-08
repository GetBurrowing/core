defmodule Platform.Chat.AgentResponderTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.RuntimePresence
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
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "main",
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

    # Go through Chat.post_message so author_* snapshots get populated
    # (ADR 0038). Historical tests that asserted on prefixed history
    # content depended on the snapshot being set.
    {:ok, message} = Platform.Chat.post_message(Map.merge(defaults, attrs))
    message
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  describe "attention-triggered agent replies" do
    test "routes a case-insensitive @zip mention into an agent reply" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "hey @zip can you help?"})

      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey @zip can you help?", opts}, 500
      assert opts[:history] == []

      replies = Chat.list_messages(space.id, limit: 10)
      reply = Enum.find(replies, &(&1.participant_id == agent_participant.id))

      assert reply
      assert reply.content == "Zip reply: hey @zip can you help?"
      assert reply.metadata["trigger"] == "mention"

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "includes recent same-scope history and ignores non-mentions" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{slug: "main-2", name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      _older_user = create_message(space.id, user.id, %{content: "Earlier context"})
      _older_agent = create_message(space.id, agent_participant.id, %{content: "Previous reply"})
      message = create_message(space.id, user.id, %{content: "No summon here"})

      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200

      mention = create_message(space.id, user.id, %{content: "@zip pick this up"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert_receive {:agent_chat_called, "@zip pick this up", opts}, 500

      assert opts[:history] == [
               %{role: "user", content: "Alice: Earlier context", attachments: []},
               %{role: "assistant", content: "Previous reply", attachments: []},
               %{role: "user", content: "Alice: No summon here", attachments: []}
             ]

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end
  end

  describe "external runtime payload attachments" do
    test "history entries carry attachment metadata; entries with none get []" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{slug: "main-attach", name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      older_with =
        create_message(space.id, user.id, %{content: "Image attached"})

      {:ok, _att} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: older_with.id,
          filename: "shot.png",
          content_type: "image/png",
          byte_size: 4,
          storage_key: "chat/test/shot-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      _older_text = create_message(space.id, agent_participant.id, %{content: "Got it"})
      mention = create_message(space.id, user.id, %{content: "@zip pick this up"})

      assert {:ok, _} = AttentionRouter.route(mention)
      assert_receive {:agent_chat_called, "@zip pick this up", opts}, 500

      history = opts[:history]
      assert is_list(history)
      assert length(history) == 2

      [first, second] = history

      assert first.role == "user"
      assert first.content == "Alice: Image attached"

      assert [%{filename: "shot.png", content_type: "image/png", byte_size: 4, url: url}] =
               first.attachments

      assert url =~ ~r|^/chat/attachments/[0-9a-fA-F-]{36}$|

      assert second.role == "assistant"
      assert second.attachments == []

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "external dispatch payload carries trigger and history attachments" do
      space = create_space()
      user = create_participant(space.id)

      # Register an external runtime + presence so dispatch_to_external proceeds
      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "ar-test-#{System.unique_integer([:positive])}@example.com",
          name: "AR Owner",
          oidc_sub: "oidc-ar-#{System.unique_integer([:positive])}"
        })

      runtime_token = "rt-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: runtime_token,
          display_name: "ext-rt"
        })

      RuntimePresence.track(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "ext-agent",
          name: "Ext",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      {:ok, _agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Ext")

      # History message with an attachment, plus one without.
      older_with = create_message(space.id, user.id, %{content: "earlier with file"})

      {:ok, _att_history} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: older_with.id,
          filename: "report.pdf",
          content_type: "application/pdf",
          byte_size: 12,
          storage_key: "chat/test/r-#{Ecto.UUID.generate()}.pdf",
          state: "ready"
        })

      _older_no_att = create_message(space.id, user.id, %{content: "earlier no file"})

      # Trigger message itself has an attachment + an @mention.
      trigger = create_message(space.id, user.id, %{content: "@ext look at this"})

      {:ok, trigger_att} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: trigger.id,
          filename: "shot.png",
          content_type: "image/png",
          byte_size: 7,
          storage_key: "chat/test/s-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      assert {:ok, _} = AttentionRouter.route(trigger)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      assert payload.message.content =~ "look at this"
      assert payload.message.author == "Alice"

      assert [%{url: url, filename: "shot.png", content_type: "image/png", byte_size: 7}] =
               payload.message.attachments

      assert url == "/chat/attachments/#{trigger_att.id}"

      # History should contain entries; the entry whose content matches
      # "earlier with file" must include the report.pdf attachment, the
      # other should have an empty list.
      with_attach =
        Enum.find(payload.history, fn h ->
          is_binary(h.content) and h.content =~ "earlier with file"
        end)

      without_attach =
        Enum.find(payload.history, fn h ->
          is_binary(h.content) and h.content =~ "earlier no file"
        end)

      assert [%{filename: "report.pdf", content_type: "application/pdf", byte_size: 12}] =
               with_attach.attachments

      assert without_attach.attachments == []

      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end
  end
end
