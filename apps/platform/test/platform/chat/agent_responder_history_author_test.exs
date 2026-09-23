defmodule Platform.Chat.AgentResponderHistoryAuthorTest do
  @moduledoc """
  Every federated `payload.history` entry names its author (task 01a0a7b2).

  The Claude Code channel plugin renders the dispatch's "Recent context" block
  itself, in `makeEmitAttention` (claude-code-suite-channel `src/attention.ts`),
  as `recent.map((h) => `${h.author}: ${h.content}`)`. Core used to send
  `%{role, content, attachments}` with no `author`, so every turn rendered as
  `undefined: ...` and a human turn as `undefined: Alice: ...`. These tests pin
  the contract the plugin reads: a structured non-blank `author` and content
  carrying NO `Name: ` prefix.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AttentionRouter
  alias Platform.Chat.Message
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, _opts), do: {:ok, %{content: "stub: #{message}", model: "stub", usage: %{}}}
  end

  # Test data only: a bracketed mention token of the second agent, so the
  # history carries a mention verbatim. It is never posted to a real space.
  @mention_body "hey @[Geordi] can you look at the logs"

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)

    :ok
  end

  defp uuid!(value) do
    {:ok, id} = Platform.UUID.cast(value)
    id
  end

  defp create_agent(attrs) do
    defaults = %{
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

  defp post!(space_id, participant_id, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    message
  end

  # Seeds, in order: Alice, a second agent (Geordi), the TaskRouter system
  # participant, Alice again with a mention token of Geordi, and one prior turn
  # by the recipient agent itself. Returns what the tests need.
  defp seed do
    unique = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "History author", slug: "hist-author-#{unique}", kind: "channel"})

    {:ok, alice} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: uuid!(Ecto.UUID.generate()),
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

    owner =
      Repo.insert!(%User{
        email: "hist-author-#{unique}@example.com",
        name: "History Owner",
        oidc_sub: "oidc-hist-author-#{unique}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-hist-author-#{unique}",
        display_name: "hist-author-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    recipient =
      create_agent(%{
        slug: "ext-hist-#{unique}",
        name: "Ext",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    {:ok, recipient_participant} =
      Chat.add_agent_participant(space.id, recipient, display_name: "Ext")

    # Geordi is external with a runtime that is NOT present, so the mention
    # of it below dead-letters instead of persisting a reply that would add
    # an unplanned turn to the recipient's history.
    geordi_runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-hist-geordi-#{unique}",
        display_name: "geordi-rt"
      })

    geordi =
      create_agent(%{
        slug: "geordi-#{unique}",
        name: "Geordi",
        runtime_type: "external",
        runtime_id: geordi_runtime.id
      })

    {:ok, geordi_participant} =
      Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

    {:ok, system_participant} = ExecutionSpace.ensure_system_participant(space.id)

    m_alice_1 = post!(space.id, alice.id, "first")
    m_geordi = post!(space.id, geordi_participant.id, "I checked the build")
    m_system = post!(space.id, system_participant.id, "Stage 1 started")
    m_mention = post!(space.id, alice.id, @mention_body)
    m_self = post!(space.id, recipient_participant.id, "on it")

    # Flush telemetry-driven routing of the seed turns BEFORE subscribing, so
    # the only attention we receive is the trigger's.
    assert :ok = GenServer.call(AttentionRouter, :__drain__)

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)

    %{
      space: space,
      alice: alice,
      recipient: recipient,
      topic: topic,
      m_geordi: m_geordi,
      m_system: m_system,
      m_alice_1: m_alice_1,
      m_mention: m_mention,
      m_self: m_self
    }
  end

  defp trigger_and_receive(%{space: space, alice: alice, recipient: recipient, topic: topic}) do
    trigger = post!(space.id, alice.id, "@#{recipient.slug} summarise please")
    assert {:ok, _} = AttentionRouter.route(trigger)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: payload
                   },
                   1500

    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    payload
  end

  # Mirrors the plugin formula in `makeEmitAttention` (claude-code-suite-channel
  # src/attention.ts): `recent.map((h) => `${h.author}: ${h.content}`)`.
  # A missing key renders as JS `undefined`, which is the defect.
  defp render_block(history) do
    Enum.map(history, fn h ->
      author = Map.get(h, "author", "undefined")
      author = if is_nil(author), do: "null", else: author
      "#{author}: #{Map.get(h, "content")}"
    end)
  end

  defp wire(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  describe "federated payload.history author" do
    test "every turn names its author, in order, with unprefixed content" do
      ctx = seed()
      payload = trigger_and_receive(ctx)

      assert Enum.map(payload.history, &Map.get(&1, :author)) ==
               ["Alice", "Geordi", "TaskRouter", "Alice", "Ext"]

      decoded = wire(payload)
      history = decoded["history"]

      assert render_block(history) == [
               "Alice: first",
               "Geordi: I checked the build",
               "TaskRouter: Stage 1 started",
               "Alice: " <> @mention_body,
               "Ext: on it"
             ]

      for entry <- history do
        assert is_binary(entry["author"]) and String.trim(entry["author"]) != "",
               "blank or missing author in #{inspect(entry)}"
      end

      block = Enum.join(render_block(history), "\n")
      refute block =~ "undefined"
      refute block =~ "Alice: Alice:"

      # The mention token survives verbatim; content is never re-rendered.
      assert Enum.any?(history, &(&1["content"] == @mention_body))
    end

    test "a nil author snapshot falls back to the participant type, never nil" do
      ctx = seed()

      ids = [ctx.m_system.id, ctx.m_geordi.id]

      {2, _} =
        from(m in Message, where: m.id in ^ids)
        |> Repo.update_all(set: [author_display_name: nil])

      payload = trigger_and_receive(ctx)

      assert Enum.map(payload.history, &Map.get(&1, :author)) ==
               ["Alice", "Agent", "System", "Alice", "Ext"]

      history = wire(payload)["history"]

      refute Enum.any?(history, &is_nil(&1["author"]))
      refute Enum.join(render_block(history), "\n") =~ "undefined"
      refute Enum.join(render_block(history), "\n") =~ "null:"

      assert render_block(history) == [
               "Alice: first",
               "Agent: I checked the build",
               "System: Stage 1 started",
               "Alice: " <> @mention_body,
               "Ext: on it"
             ]
    end
  end
end
