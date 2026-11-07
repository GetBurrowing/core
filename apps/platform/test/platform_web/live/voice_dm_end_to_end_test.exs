defmodule PlatformWeb.VoiceDmEndToEndTest do
  @moduledoc """
  A Voice tab session end to end into the user<->agent DM (task 01a1b6c3,
  the stage 3 acceptance cases), driven through `/voice` exactly as the
  VoiceTab hook drives it (`render_hook/3`), with LiveKit stubbed.

    1. No context: the DM holds the six distinct final turns in order, each
       authored by its side and tagged, then ONE summary; nothing else.
    2. With a context: the user's context-time turns live in the context
       only; the DM holds the agent's turns, ONE pointer, the no-context
       user turn and the summary.
    3. No re-reply: every voice row routes to nobody (`:voice_record`); a
       typed control message in the same DM routes `:directed` and reaches
       the agent's runtime.
    4. Reload and recall: a fresh `/chat` mount shows the bracket with every
       turn; the agent's `space_get_messages` read and the history the
       responder sends with the next typed message carry every turn.

  Fixture names are generic: "Test User", "Helper Agent", "#general-test".
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Federation
  alias Platform.Federation.{RuntimePresence, ToolSurface}
  alias Platform.Repo

  # ── rig ───────────────────────────────────────────────────────────────

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :voice_dm_e2e}))
    Req.Test.stub(:voice_dm_e2e, fn conn -> Req.Test.json(conn, %{}) end)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original)
      Application.delete_env(:platform, :livekit_req_client)

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

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     user: user,
     agent: agent,
     topic: topic}
  end

  defp user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        name: "Test User",
        email: "voice-e2e-#{n}@example.com",
        oidc_sub: "oidc-voice-e2e-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    # A member of the install's root org, as every signed-in internal user is.
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

  # Helper Agent is the default voice partner (slug "meeting-assistant"),
  # reachable by voice, and an external agent with an ONLINE runtime whose
  # topic the test subscribes to, so a chat dispatch is observable. Its
  # runtime is the user's own (the owner caps what the agent may read, and an
  # owner outside the DM could not let it read the DM at all).
  defp helper_agent!(owner) do
    from(a in Agent, where: a.slug == "meeting-assistant")
    |> Repo.update_all(
      set: [slug: "meeting-assistant-old-#{System.unique_integer([:positive])}", status: "paused"]
    )

    n = System.unique_integer([:positive])

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-voice-e2e-#{n}",
        display_name: "voice-e2e-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "meeting-assistant",
        name: "Helper Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        runtime_type: "external",
        runtime_id: runtime.id,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert!()

    # The runtime carries its agent and the default tool profile, as a linked
    # runtime does, so the agent's own tool reads are authorised.
    runtime = Repo.update!(Ecto.Changeset.change(runtime, agent_id: agent.id))

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        AgentRuntime.default_tool_profile(),
        nil
      )

    {:ok, _voice_runtime, _raw} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => "meeting-voice-agent"
          }
        }
      })

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    {Repo.reload(agent), topic}
  end

  defp channel!(user, name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp hook(view, event, params \\ %{}),
    do: view |> element("#voice-area") |> render_hook(event, params)

  defp turn(view, who, text, opts \\ []) do
    params =
      %{"who" => who, "text" => text, "final" => Keyword.get(opts, :final, true)}
      |> then(&if(opts[:seg], do: Map.put(&1, "segment_id", opts[:seg]), else: &1))

    hook(view, "voice_turn", params)
  end

  defp start_voice!(conn) do
    {:ok, view, _html} = live(conn, ~p"/voice")
    hook(view, "voice_start")
    assert_reply(view, %{ok: true})
    view
  end

  defp end_voice!(view) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, {:shutdown, :closed})
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  defp session_id(view), do: :sys.get_state(view.pid).socket.assigns.session.id

  defp dm!(user, agent) do
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    dm
  end

  defp rows(space_id) do
    from(m in Message, where: m.space_id == ^space_id, order_by: [asc: m.id]) |> Repo.all()
  end

  defp author(%Message{participant_id: pid}) do
    p = Repo.get!(Participant, pid)
    {p.participant_type, p.participant_id}
  end

  # Case 1's session: 3 + 3 distinct finals, one non-final, one duplicate.
  defp no_context_session!(conn) do
    view = start_voice!(conn)
    id = session_id(view)

    turn(view, "me", "first question", seg: "SG_me_1")
    turn(view, "agent", "first answer", seg: "SG_ag_1")
    turn(view, "me", "a half thought", final: false, seg: "SG_me_x")
    turn(view, "me", "second question", seg: "SG_me_2")
    turn(view, "agent", "second answer", seg: "SG_ag_2")
    turn(view, "agent", "second answer", seg: "SG_ag_2")
    turn(view, "me", "third question", seg: "SG_me_3")
    turn(view, "agent", "third answer", seg: "SG_ag_3")
    end_voice!(view)
    id
  end

  @spoken [
    "first question",
    "first answer",
    "second question",
    "second answer",
    "third question",
    "third answer"
  ]

  # ── case 1 ────────────────────────────────────────────────────────────

  test "case 1, no context: six finals in spoken order, one summary, nothing elsewhere", %{
    conn: conn,
    user: user,
    agent: agent
  } do
    id = no_context_session!(conn)
    dm = dm!(user, agent)
    [s | turns] = Enum.reverse(rows(dm.id))
    turns = Enum.reverse(turns)

    assert Enum.map(turns, & &1.content) == @spoken
    refute Enum.any?(rows(dm.id), &(&1.content == "a half thought"))

    for {row, i} <- Enum.with_index(turns, 1) do
      who = if rem(i, 2) == 1, do: {"user", user.id}, else: {"agent", agent.id}
      assert author(row) == who
      assert row.metadata["source"] == "voice"
      assert row.metadata["voice_session_id"] == id
      assert row.metadata["voice_turn"] == i
    end

    assert s.content =~ ~r/^Voice chat · 6 turns · \d+ min$/
    assert s.metadata["voice_kind"] == "summary"
    assert s.metadata["voice_session_id"] == id

    elsewhere =
      from(m in Message,
        where: m.space_id != ^dm.id,
        where: fragment("?->>'voice_session_id' = ?", m.metadata, ^id)
      )
      |> Repo.aggregate(:count)

    assert elsewhere == 0
  end

  # ── case 2 ────────────────────────────────────────────────────────────

  test "case 2, with context: your side in #general-test, the DM gets one pointer", %{
    conn: conn,
    user: user,
    agent: agent
  } do
    ctx = channel!(user, "general-test")
    view = start_voice!(conn)
    view |> element("#ctx") |> render_click()
    view |> element("#ctx-opt-#{ctx.id}") |> render_click()

    turn(view, "me", "ctx q1")
    turn(view, "agent", "ctx a1")
    turn(view, "me", "ctx q2")
    turn(view, "agent", "ctx a2")

    metas =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".bubble.me .meta")
      |> Enum.map(&LazyHTML.text/1)

    assert length(metas) == 2
    assert Enum.all?(metas, &String.ends_with?(&1, " · posted to general-test"))

    view |> element("#ctx") |> render_click()
    view |> element("#ctx-opt-none") |> render_click()
    turn(view, "me", "plain q3")
    turn(view, "agent", "plain a3")
    end_voice!(view)

    in_ctx = rows(ctx.id)
    assert Enum.map(in_ctx, & &1.content) == ["ctx q1", "ctx q2"]

    assert Enum.all?(
             in_ctx,
             &(&1.metadata["source"] == "voice" and author(&1) == {"user", user.id})
           )

    dm = dm!(user, agent)
    contents = Enum.map(rows(dm.id), & &1.content)

    assert [
             "Your side was posted to #general-test",
             "ctx a1",
             "ctx a2",
             "plain q3",
             "plain a3",
             summary
           ] = contents

    assert summary =~ ~r/^Voice chat · 6 turns · \d+ min$/
    assert Enum.count(contents, &String.starts_with?(&1, "Your side was posted")) == 1
    assert MapSet.disjoint?(MapSet.new(contents), MapSet.new(Enum.map(in_ctx, & &1.content)))
  end

  # ── case 3 ────────────────────────────────────────────────────────────

  test "case 3, no re-reply: voice rows route to nobody; a typed control routes :directed", %{
    conn: conn,
    user: user,
    agent: agent,
    topic: topic
  } do
    test_pid = self()
    handler = "voice-e2e-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:platform, :chat, :attention_routed], [:platform, :chat, :attention_skipped]],
        fn event, _m, meta, _ -> send(test_pid, {List.last(event), meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    dm = dm!(user, agent)
    :ok = Chat.PubSub.subscribe(dm.id)
    _id = no_context_session!(conn)
    :ok = GenServer.call(AttentionRouter, :__drain__)

    voice_rows = rows(dm.id)
    assert length(voice_rows) == 7

    for %{id: mid} <- voice_rows do
      assert_received {:attention_skipped, %{message_id: ^mid, reason: :voice_record}}
      refute_received {:attention_routed, %{message_id: ^mid}}

      refute_received %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "attention",
        payload: %{signal: %{message_id: ^mid}}
      }
    end

    # Nothing answered the session.
    assert length(rows(dm.id)) == 7

    # CONTROL: a typed message in the same DM is routed and dispatched.
    user_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "user",
        participant_id: user.id
      )

    {:ok, typed} =
      Chat.post_message(%{
        space_id: dm.id,
        participant_id: user_p.id,
        content_type: "text",
        content: "what did we say about the third question?"
      })

    :ok = GenServer.call(AttentionRouter, :__drain__)
    typed_id = typed.id
    assert_receive {:attention_routed, %{message_id: ^typed_id} = routed}, 2_000
    assert inspect(routed) =~ ":directed"

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^typed_id}} = payload
                   },
                   2_000

    # Case 4's second read: the history the responder sends with that
    # typed message carries every spoken turn, in order.
    history = payload.history |> Enum.map(&(&1[:content] || &1["content"])) |> Enum.join("\n")
    positions = Enum.map(@spoken, fn t -> :binary.match(history, t) end)
    assert Enum.all?(positions, &match?({_, _}, &1))
    assert positions == Enum.sort(positions)
  end

  # ── case 4 ────────────────────────────────────────────────────────────

  test "case 4, reload and recall: the bracket after a fresh mount; the agent reads every turn",
       %{conn: conn, user: user, agent: agent} do
    id = no_context_session!(conn)
    dm = dm!(user, agent)

    {:ok, chat, _} = live(conn, ~p"/chat/#{dm.id}")
    doc = chat |> render() |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query("[data-role='voice-session-header']") |> Enum.count() == 1
    assert doc |> LazyHTML.query("[data-role='voice-summary-card']") |> Enum.count() == 1

    shown =
      doc
      |> LazyHTML.query("#message-list [data-voice-session='#{id}']")
      |> Enum.map(&LazyHTML.text/1)
      |> Enum.join("\n")

    positions = Enum.map(@spoken, fn t -> :binary.match(shown, t) end)
    assert Enum.all?(positions, &match?({_, _}, &1))
    assert positions == Enum.sort(positions)

    runtime = Repo.get!(AgentRuntime, agent.runtime_id)

    {:ok, %{messages: messages}} =
      ToolSurface.execute("space_get_messages", %{"space_id" => dm.id}, %{
        agent_id: agent.id,
        runtime_id: runtime.runtime_id
      })

    oldest_first = Enum.reverse(messages)
    spoken = Enum.filter(oldest_first, &(&1.voice && &1.voice.voice_turn))
    assert Enum.map(spoken, & &1.content) == @spoken
    assert Enum.all?(spoken, &(&1.voice.voice_session_id == id))
    assert Enum.map(spoken, & &1.voice.voice_turn) == Enum.to_list(1..6)

    assert [%{voice: %{voice_kind: "summary"}}] =
             Enum.filter(oldest_first, &(&1.voice && &1.voice.voice_kind))
  end
end
