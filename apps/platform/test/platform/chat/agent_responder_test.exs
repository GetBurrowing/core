defmodule Platform.Chat.AgentResponderTest do
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

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

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
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

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
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

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
               %{role: "user", content: "Alice: Earlier context"},
               %{role: "assistant", content: "Previous reply"},
               %{role: "user", content: "Alice: No summon here"}
             ]

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end
  end
end
