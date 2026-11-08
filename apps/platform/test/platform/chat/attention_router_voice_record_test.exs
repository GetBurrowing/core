defmodule Platform.Chat.AttentionRouterVoiceRecordTest do
  @moduledoc """
  A Voice tab record in a user<->agent DM routes to nobody (voice DM
  stage 1).

  A voice record is a message whose metadata carries `"source" => "voice"`
  AND a `"voice_session_id"`. In a DM every message is routed to the agent as
  `:directed`, so without the `dm_voice_record?/2` exit in
  `AttentionRouter.do_route/2` the agent would answer its own voice
  conversation by text.

  The DM's agent is external with a registered, ONLINE runtime, and the test
  subscribes to that runtime's topic, so a dispatch is observable as an
  `"attention"` broadcast. The positive controls pin that the fixture can
  fail: a plain message in the same DM IS broadcast to the runtime.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation.RuntimePresence

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      if previous_mode,
        do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
        else: Application.delete_env(:platform, :chat_agent_dispatch_mode)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    test_pid = self()
    handler_id = "voice-record-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:platform, :chat, :attention_routed], [:platform, :chat, :attention_skipped]],
        fn event, _measurements, meta, _ -> send(test_pid, {List.last(event), meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = user!()
    {agent, topic} = online_external_agent!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    user_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "user",
        participant_id: user.id
      )

    agent_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "agent",
        participant_id: agent.id
      )

    :ok = ChatPubSub.subscribe(dm.id)

    %{dm: dm, user_p: user_p, agent_p: agent_p, agent: agent, topic: topic}
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-record-#{n}@example.com",
      name: "Test User",
      oidc_sub: "oidc-voice-record-#{n}"
    })
  end

  defp online_external_agent! do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "voice-owner-#{n}@example.com",
        name: "Owner",
        oidc_sub: "oidc-voice-owner-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-voice-#{n}",
        display_name: "voice-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "helper-agent-#{n}",
        name: "Helper Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        runtime_type: "external",
        runtime_id: runtime.id,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert!()

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    {agent, topic}
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  @voice_text "the Voice tab heard this line"

  defp voice_metadata, do: %{"source" => "voice", "voice_session_id" => Ecto.UUID.generate()}

  # Inserted without `Chat.post_message/1` so the ONLY routing is the explicit
  # `AttentionRouter.route/1` below, and every observation belongs to it.
  defp insert!(space, participant, metadata) do
    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: @voice_text,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp refute_dispatched(topic, message_id) do
    refute_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^message_id}}
                   },
                   300

    refute_received {:attention_needed, %{message_id: ^message_id}}
    refute_received {:attention_routed, %{message_id: ^message_id}}
  end

  defp assert_dispatched(topic, message_id) do
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^message_id}}
                   },
                   2_000
  end

  describe "POSITIVE CONTROL: the fixture can fail" do
    test "the same text WITHOUT the voice metadata routes :directed and reaches the runtime",
         %{dm: dm, user_p: user_p, agent_p: agent_p, topic: topic} do
      message = insert!(dm, user_p, %{})
      agent_p_id = agent_p.id

      assert {:ok, [%{participant_id: ^agent_p_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_dispatched(topic, message.id)
      message_id = message.id
      assert_received {:attention_needed, %{message_id: ^message_id, reason: :directed}}
      drain()
    end

    test "source voice WITHOUT a voice_session_id is not a record and still routes :directed",
         %{dm: dm, user_p: user_p, agent_p: agent_p, topic: topic} do
      message = insert!(dm, user_p, %{"source" => "voice"})
      agent_p_id = agent_p.id

      assert {:ok, [%{participant_id: ^agent_p_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_dispatched(topic, message.id)
      drain()
    end
  end

  describe "a voice record in a user<->agent DM" do
    test "user-authored: routes to [] with reason :voice_record, no dispatch, mutex untouched",
         %{dm: dm, user_p: user_p, topic: topic} do
      sentinel = Ecto.UUID.generate()
      ActiveAgentStore.set_active(dm.id, sentinel)
      before = ActiveAgentStore.get_active(dm.id)

      message = insert!(dm, user_p, voice_metadata())
      assert AttentionRouter.voice_record?(message)

      assert {:ok, []} = AttentionRouter.route(message)
      message_id = message.id
      assert_received {:attention_skipped, %{message_id: ^message_id, reason: :voice_record}}

      refute_dispatched(topic, message.id)
      assert ActiveAgentStore.get_active(dm.id) == before
      drain()
    end

    test "agent-authored: routes to [] with reason :voice_record and pushes no human",
         %{dm: dm, agent_p: agent_p, topic: topic} do
      # CONTROL: a plain agent message in the DM DOES route the human.
      control = insert!(dm, agent_p, %{})
      assert {:ok, [_ | _]} = AttentionRouter.route(control)
      control_id = control.id
      assert_received {:attention_needed, %{message_id: ^control_id}}

      before = ActiveAgentStore.get_active(dm.id)
      message = insert!(dm, agent_p, voice_metadata())

      assert {:ok, []} = AttentionRouter.route(message)
      message_id = message.id
      assert_received {:attention_skipped, %{message_id: ^message_id, reason: :voice_record}}

      refute_dispatched(topic, message.id)
      assert ActiveAgentStore.get_active(dm.id) == before
      drain()
    end

    test "posted through Chat.post_message/1, the telemetry route dispatches nothing either",
         %{dm: dm, user_p: user_p, topic: topic} do
      {:ok, message} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: user_p.id,
          content_type: "text",
          content: @voice_text,
          metadata: voice_metadata()
        })

      drain()
      message_id = message.id
      # PubSub delivery to open screens is unaffected.
      assert_received {:new_message, %Message{id: ^message_id}}
      assert_received {:attention_skipped, %{message_id: ^message_id, reason: :voice_record}}
      refute_dispatched(topic, message.id)
    end
  end

  describe "a voice line in a CHANNEL (the Voice tab's context post)" do
    test "still routes as before: the armed mutex holder gets its decision", %{agent: agent} do
      n = System.unique_integer([:positive])

      {:ok, channel} =
        Chat.create_space(%{name: "General Test", slug: "general-test-#{n}", kind: "channel"})

      {:ok, person} =
        Chat.add_participant(channel.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Test User",
          joined_at: DateTime.utc_now()
        })

      {:ok, agent_p} = Chat.add_agent_participant(channel.id, agent, display_name: "Helper Agent")
      Chat.add_space_agent(channel.id, agent.id, role: "principal")
      ActiveAgentStore.set_active(channel.id, agent_p.id)

      message = insert!(channel, person, voice_metadata())
      assert AttentionRouter.voice_record?(message)
      refute AttentionRouter.dm_voice_record?(message, "channel")

      {:ok, decisions} = AttentionRouter.route(message)
      assert Enum.any?(decisions, &(&1.participant_id == agent_p.id))
      message_id = message.id
      refute_received {:attention_skipped, %{message_id: ^message_id}}
      drain()
    end
  end

  describe "voice_record?/1 and dm_voice_record?/2" do
    test "need source voice AND a non-blank voice_session_id; the exclusion also needs a DM" do
      id = Ecto.UUID.generate()
      record = %Message{metadata: %{"source" => "voice", "voice_session_id" => id}}

      assert AttentionRouter.voice_record?(record)
      refute AttentionRouter.voice_record?(%Message{metadata: %{"source" => "voice"}})

      refute AttentionRouter.voice_record?(%Message{
               metadata: %{"source" => "voice", "voice_session_id" => ""}
             })

      refute AttentionRouter.voice_record?(%Message{
               metadata: %{"source" => "external_runtime", "voice_session_id" => id}
             })

      refute AttentionRouter.voice_record?(%Message{metadata: %{}})

      assert AttentionRouter.dm_voice_record?(record, "dm")

      for kind <- ~w(channel group execution meeting system) do
        refute AttentionRouter.dm_voice_record?(record, kind)
      end

      refute AttentionRouter.dm_voice_record?(record, nil)
    end
  end
end
