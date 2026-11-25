defmodule Platform.Meetings.OnDeviceVoiceTest do
  @moduledoc """
  `Platform.Meetings.OnDeviceVoice` (task 01a20dc5 stage 2): an on-device
  Voice turn is a PLAIN DM text message, so the attention router sends it
  `:directed` to the agent's runtime (unlike a voice row, which routes to
  nobody); the agent's next message is the reply; the reply is read without
  markdown.

  The routing rig is `PlatformWeb.VoiceDmEndToEndTest`'s (case 3's control
  message): an external agent with an online runtime whose topic the test
  subscribes to. Fixture names are generic.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message}
  alias Platform.Federation.RuntimePresence
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Repo

  doctest Platform.Meetings.OnDeviceVoice

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      if previous_mode,
        do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
        else: Application.delete_env(:platform, :chat_agent_dispatch_mode)
    end)

    for {name, spec} <- [
          {AttentionRouter, {AttentionRouter, []}},
          {ActiveAgentStore, {ActiveAgentStore, []}},
          {RuntimePresence, RuntimePresence}
        ] do
      pid = Process.whereis(name) || start_supervised!(spec)
      Sandbox.allow(Repo, self(), pid)
    end

    user = user!()
    {agent, topic} = helper_agent!(user)
    {:ok, conn} = OnDeviceVoice.open(user, agent)
    {:ok, user: user, agent: agent, topic: topic, voice: conn}
  end

  # ── routing ───────────────────────────────────────────────────────────

  test "a turn is a plain DM message that routes :directed and reaches the agent's runtime",
       %{voice: voice, topic: topic} do
    test_pid = self()
    handler = "on-device-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:platform, :chat, :attention_routed], [:platform, :chat, :attention_skipped]],
        fn event, _m, meta, _ -> send(test_pid, {List.last(event), meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, voice, message} = OnDeviceVoice.send_turn(voice, "  what is left on the list  ", "ct-1")
    :ok = GenServer.call(AttentionRouter, :__drain__)
    mid = message.id

    refute_received {:attention_skipped, %{message_id: ^mid}}
    assert_receive {:attention_routed, %{message_id: ^mid} = routed}, 2_000
    assert inspect(routed) =~ ":directed"

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^mid}}
                   },
                   2_000

    # Routing first (above), then the row itself.
    # The words said, then the streaming instruction (task 01a20fdd stage 3).
    assert message.content == "what is left on the list\n\n" <> OnDeviceVoice.instruction()
    assert OnDeviceVoice.user_text(message.content) == "what is left on the list"
    assert message.content_type == "text"
    assert message.space_id == voice.space_id
    assert message.participant_id == voice.user_participant_id
    assert message.metadata == %{"input" => "on_device", "client_turn_id" => "ct-1"}
    refute Map.has_key?(message.metadata, "source")
    refute Map.has_key?(message.metadata, "voice_session_id")
    assert voice.turn_at == message.inserted_at
  end

  test "a blank turn posts nothing", %{voice: voice} do
    assert {:error, :blank} = OnDeviceVoice.send_turn(voice, "   ", "ct-blank")
    assert rows(voice.space_id) == []
  end

  test "find_turn/2 returns the turn already posted with that client_turn_id", %{voice: voice} do
    assert OnDeviceVoice.find_turn(voice, "ct-2") == nil
    {:ok, _voice, message} = OnDeviceVoice.send_turn(voice, "hello", "ct-2")
    assert OnDeviceVoice.find_turn(voice, "ct-2").id == message.id
    assert OnDeviceVoice.find_turn(voice, "ct-other") == nil
  end

  # ── the reply ─────────────────────────────────────────────────────────

  test "agent_reply?/2 takes the agent's message after the turn, never the user's own",
       %{voice: voice} do
    {:ok, before} = post_as(voice.agent_participant_id, voice.space_id, "an earlier note")
    refute OnDeviceVoice.agent_reply?(voice, before), "no turn yet: nothing is a reply"

    {:ok, voice, turn} = OnDeviceVoice.send_turn(voice, "what is left", "ct-3")
    refute OnDeviceVoice.agent_reply?(voice, turn), "the user's own turn is not a reply"

    {:ok, reply} = post_as(voice.agent_participant_id, voice.space_id, "Three items")
    assert OnDeviceVoice.agent_reply?(voice, reply)

    refute OnDeviceVoice.agent_reply?(voice, %{reply | space_id: Ecto.UUID.generate()})
    refute OnDeviceVoice.agent_reply?(voice, %{reply | content: "  "})

    refute OnDeviceVoice.agent_reply?(voice, %{
             reply
             | inserted_at: DateTime.add(voice.turn_at, -1, :second)
           })

    refute OnDeviceVoice.agent_reply?(nil, reply)
  end

  describe "speakable_text/1" do
    for {input, expected} <- [
          {"**Three items:** the deck", "Three items: the deck"},
          {"# Plan\n\n- one\n- two\n1. three", "Plan one two three"},
          {"see [the doc](https://example.com/x) and ![chart](https://example.com/c.png)",
           "see the doc and chart"},
          {"run `mix test` now", "run mix test now"},
          {"```elixir\nIO.puts(1)\n```\nok", "IO.puts(1) ok"},
          {"> quoted *soft* and _also_ ~~gone~~", "quoted soft and also gone"},
          {"snake_case_name stays, 2 * 3 * 4 stays", "snake_case_name stays, 2 * 3 * 4 stays"},
          {"---\nafter the rule", "after the rule"},
          {nil, ""}
        ] do
      test "#{inspect(input)}" do
        assert OnDeviceVoice.speakable_text(unquote(input)) == unquote(expected)
      end
    end
  end

  # ── streamed sentences (task 01a20fdd stage 3) ──────────────────────

  describe "speakable_sentences/3" do
    test "only complete sentences; the unfinished tail waits" do
      assert OnDeviceVoice.speakable_sentences(0, "First one. Second", false) ==
               {["First one."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "First one.", false) == {[], 0}
      assert OnDeviceVoice.speakable_sentences(0, "First one. ", false) == {["First one."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "Is it? Yes! Ok", false) ==
               {["Is it?", "Yes!"], 2}
    end

    test "cumulative text: only the sentences past `spoken`" do
      text = "One. Two. Three"
      assert OnDeviceVoice.speakable_sentences(0, text, false) == {["One.", "Two."], 2}
      assert OnDeviceVoice.speakable_sentences(2, text, false) == {[], 2}

      assert OnDeviceVoice.speakable_sentences(2, text <> " and four. ", false) ==
               {["Three and four."], 3}
    end

    test "abbreviations and initials are held back, a decimal never splits" do
      assert OnDeviceVoice.speakable_sentences(0, "Use a tool, e.g. a hammer. Next", false) ==
               {["Use a tool, e.g. a hammer."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "Call Dr. Lee and Mr. Hale. Then", false) ==
               {["Call Dr. Lee and Mr. Hale."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "It costs 3.5 dollars. Ok", false) ==
               {["It costs 3.5 dollars."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "Ask J. Smith first. Then", false) ==
               {["Ask J. Smith first."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "So do I. Next", false) == {["So do I."], 1}
    end

    test "a newline ends a sentence, and markdown is stripped" do
      text = "**Three items:** the deck\n- one\n- two"

      assert OnDeviceVoice.speakable_sentences(0, text, false) ==
               {["Three items: the deck", "one"], 2}

      assert OnDeviceVoice.speakable_sentences(0, "Use `mix test`. **Bold", false) ==
               {["Use mix test."], 1}

      assert OnDeviceVoice.speakable_sentences(0, "```\n---\nAfter.\n", false) == {["After."], 1}
    end

    test "final flushes the tail; an empty final speaks nothing" do
      assert OnDeviceVoice.speakable_sentences(1, "One. And the rest", true) ==
               {["And the rest"], 2}

      assert OnDeviceVoice.speakable_sentences(0, "", true) == {[], 0}
      assert OnDeviceVoice.speakable_sentences(0, nil, true) == {[], 0}
      assert OnDeviceVoice.speakable_sentences(3, "Short.", true) == {[], 3}
    end
  end

  describe "agent_chunk?/2" do
    test "the agent's chunk in the conn's DM after a turn; nothing else", %{voice: voice} do
      chunk = %{
        space_id: voice.space_id,
        chunk_id: "c1",
        text: "Hi",
        done: false,
        participant_id: voice.agent_participant_id
      }

      refute OnDeviceVoice.agent_chunk?(voice, chunk), "no turn yet"
      {:ok, voice, _turn} = OnDeviceVoice.send_turn(voice, "hello", "ct-chunk")
      assert OnDeviceVoice.agent_chunk?(voice, chunk)

      refute OnDeviceVoice.agent_chunk?(voice, %{
               chunk
               | participant_id: voice.user_participant_id
             })

      refute OnDeviceVoice.agent_chunk?(voice, %{chunk | space_id: Ecto.UUID.generate()})
      refute OnDeviceVoice.agent_chunk?(voice, %{chunk | text: nil})
      refute OnDeviceVoice.agent_chunk?(nil, chunk)
    end
  end

  # ── rig ───────────────────────────────────────────────────────────────

  defp post_as(participant_id, space_id, text) do
    Chat.post_message(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: text
    })
  end

  defp rows(space_id) do
    from(m in Message, where: m.space_id == ^space_id, order_by: [asc: m.id]) |> Repo.all()
  end

  defp user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        name: "Test User",
        email: "on-device-#{n}@example.com",
        oidc_sub: "oidc-on-device-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    root = Platform.Tenancy.get_org_by_slug!(Platform.Tenancy.root_org_slug())

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: root.id,
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  # An external agent with an ONLINE runtime owned by the user, whose topic
  # the test subscribes to so a chat dispatch is observable. No voice
  # runtime: the on-device path needs none.
  defp helper_agent!(owner) do
    n = System.unique_integer([:positive])

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-on-device-#{n}",
        display_name: "on-device-rt"
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

    runtime = Repo.update!(Ecto.Changeset.change(runtime, agent_id: agent.id))

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        AgentRuntime.default_tool_profile(),
        nil
      )

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    {Repo.reload(agent), topic}
  end
end
