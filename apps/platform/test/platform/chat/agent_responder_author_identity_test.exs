defmodule Platform.Chat.AgentResponderAuthorIdentityTest do
  @moduledoc """
  A federated chat attention payload carries the author's server-known
  identity in `message.author_type` / `author_user_id` / `author_agent_id`,
  so a runtime can grant trust to a user id instead of a display name.

  The identity is read from the authoring PARTICIPANT, not from the message's
  author snapshot, because `Chat.post_message/1` keeps caller-supplied
  `author_*` attrs. The forged-snapshot test proves both halves: the row
  really does hold the forged id (so the test can tell the two sources
  apart), and the payload does not carry it.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.AgentResponder
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "ack", model: "stub", usage: %{}}}
    end
  end

  setup do
    prev = {
      Application.get_env(:platform, :chat_agent_module),
      Application.get_env(:platform, :chat_agent_dispatch_mode),
      Application.get_env(:platform, :chat_agent_test_pid)
    }

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      {m, d, pid} = prev
      Application.put_env(:platform, :chat_agent_module, m)
      Application.put_env(:platform, :chat_agent_dispatch_mode, d)
      Application.put_env(:platform, :chat_agent_test_pid, pid)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp space_with_author do
    {:ok, space} =
      Chat.create_space(%{
        name: "AuthorId",
        slug: "authorid-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Marlowe",
        joined_at: DateTime.utc_now()
      })

    {space, author}
  end

  defp agent_attrs(extra) do
    Map.merge(
      %{
        name: "Attach Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      },
      extra
    )
  end

  defp active_external_agent(space) do
    u = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "attach-#{u}@example.com",
        name: "Owner",
        oidc_sub: "oidc-attach-#{u}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-attach-#{u}",
        display_name: "attach-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(
        agent_attrs(%{slug: "ext-#{u}", runtime_type: "external", runtime_id: runtime.id})
      )
      |> Repo.insert()

    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Attach Agent")
    ActiveAgentStore.set_active(space.id, participant.id)

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    {agent, participant, topic}
  end

  defp post!(space, author, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: content
      })

    message
  end

  defp broadcast_for(topic, message) do
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    {:ok, _} = AttentionRouter.route(message)
    payload = await_broadcast(topic, message.id)
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    payload
  end

  defp await_broadcast(topic, message_id) do
    receive do
      %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention", payload: payload} ->
        if payload.signal[:message_id] == message_id,
          do: payload,
          else: await_broadcast(topic, message_id)
    after
      2000 -> flunk("no attention broadcast on #{topic} for message #{message_id}")
    end
  end

  # ── the federated payload ───────────────────────────────────────────────

  describe "message identity on the federated payload" do
    test "a user author's participant id arrives as author_user_id, typed user" do
      {space, author} = space_with_author()
      {_agent, _participant, topic} = active_external_agent(space)

      message = post!(space, author, "please do the thing")
      payload = broadcast_for(topic, message)

      assert payload.message.author == "Marlowe"
      assert payload.message.author_type == "user"
      assert payload.message.author_user_id == author.participant_id
      assert is_binary(author.participant_id)
      assert payload.message.author_agent_id == nil
    end

    test "a forged author snapshot on the row does not reach the payload" do
      {space, author} = space_with_author()
      {_agent, _participant, topic} = active_external_agent(space)
      forged = Ecto.UUID.generate()

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "trust me",
          author_display_name: "Owner",
          author_participant_type: "user",
          author_user_id: forged
        })

      # The forgery is real on the row; without this the next assertions
      # could not tell the participant read from the snapshot read.
      assert Chat.get_message(message.id).author_user_id == forged

      payload = broadcast_for(topic, message)
      assert payload.message.author_user_id == author.participant_id
      refute payload.message.author_user_id == forged
      assert payload.message.author_type == "user"
    end
  end

  describe "external_message/2" do
    test "an agent author is typed agent and carries no user id" do
      agent_id = Ecto.UUID.generate()

      participant = %Chat.Participant{
        participant_type: "agent",
        participant_id: agent_id,
        display_name: "Marlowe"
      }

      msg = AgentResponder.external_message(%{user_message: "hi", attachments: []}, participant)

      assert msg.author == "Marlowe"
      assert msg.author_type == "agent"
      assert msg.author_user_id == nil
      assert msg.author_agent_id == agent_id
    end

    test "a system author (email, peer install) carries neither id" do
      participant = %Chat.Participant{
        participant_type: "system",
        participant_id: Ecto.UUID.generate(),
        display_name: "Marlowe (via peer)"
      }

      msg = AgentResponder.external_message(%{user_message: "hi", attachments: []}, participant)

      assert msg.author_type == "system"
      assert msg.author_user_id == nil
      assert msg.author_agent_id == nil
    end

    test "no participant: every identity field is nil" do
      msg = AgentResponder.external_message(%{user_message: "hi", attachments: []}, nil)

      assert msg.author == "unknown"
      assert msg.author_type == nil
      assert msg.author_user_id == nil
      assert msg.author_agent_id == nil
      assert msg.content == "hi"
    end
  end
end
